<#
  测速网站（本地，仅 localhost 可访问）
  用法：双击根目录的「启动测速网站.cmd」，或
        powershell -NoProfile -ExecutionPolicy Bypass -File app\dashboard.ps1 [-Port 8765] [-NoBrowser]
  关闭：关掉运行它的命令行窗口即可（定时测速不受影响）。
#>
param(
    [int]$Port = 0,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root    = Split-Path -Parent $Here
$WebDir  = Join-Path $Root 'web'
$DataDir = Join-Path $Root 'data'
$CsvPath = Join-Path $DataDir 'latency.csv'
$LogDir  = Join-Path $DataDir 'logs'
$LockFile = Join-Path $DataDir 'run.lock'
$Runner  = Join-Path $Here 'web-run.ps1'
$Script  = Join-Path $Here 'latency.ps1'
$CfgFile = Join-Path $Root 'config\config.psd1'
$ScheduleOverride = Join-Path $Root 'config\schedule.json'   # 网页上保存的定时设置，优先于 config.psd1
$InstallScript = Join-Path $Here 'install-schedule.ps1'
$BackupDir = Join-Path $DataDir 'backup'
$Columns = '时间','时段','区域','位置','中位ms','最快ms','最慢ms','超时次数','超1秒次数','样本数','地址','去程路径','回程路径'
New-Item -ItemType Directory -Force $LogDir | Out-Null

$cfg = if (Test-Path $CfgFile) { Import-PowerShellDataFile $CfgFile } else { @{} }
$Label = if ($cfg.SiteLabel) { $cfg.SiteLabel } else { '本机' }
if (-not $Port) { $Port = if ($cfg.DashboardPort) { [int]$cfg.DashboardPort } else { 8765 } }
$TaskName = if ($cfg.Schedule -and $cfg.Schedule.TaskName) { $cfg.Schedule.TaskName } else { 'CloudLatencyProbe' }
$Token = [guid]::NewGuid().ToString('N')
$script:Run = $null
$RegionInfo = (& $Script -ListRegions | Out-String) | ConvertFrom-Json   # 区域目录（启动时读取一次）

# ---------- 工具函数 ----------
function Send-Bytes($ctx, [int]$code, [string]$ctype, [byte[]]$bytes) {
    $r = $ctx.Response
    $r.StatusCode = $code
    $r.ContentType = $ctype
    $r.Headers['Cache-Control'] = 'no-store'
    $r.ContentLength64 = $bytes.Length
    $r.OutputStream.Write($bytes, 0, $bytes.Length)
    $r.OutputStream.Close()
}
function Send-Text($ctx, [int]$code, [string]$ctype, [string]$text) { Send-Bytes $ctx $code $ctype ([Text.Encoding]::UTF8.GetBytes($text)) }
function Send-Json($ctx, $obj, [int]$code = 200) { Send-Text $ctx $code 'application/json; charset=utf-8' ($obj | ConvertTo-Json -Depth 6 -Compress) }
function Read-Body($req) {
    $raw = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
    if ($raw) { $raw | ConvertFrom-Json } else { [pscustomobject]@{} }
}
function Read-Shared([string]$path) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')   # 允许在其他进程写入时读取
    try { (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)).ReadToEnd() } finally { $fs.Close() }
}

# 定时任务一律通过任务计划 COM 接口读写（约 20 毫秒）；Get-ScheduledTask 等命令每次要 2 秒多，会让网页按钮卡住。
# 任务未安装时返回 $null；COM 接口不可用时抛出异常，调用处退回原来的命令。
function Get-TaskCom {
    $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
    try { $svc.GetFolder('\').GetTask($TaskName) } catch { $null }
}
$TaskStates = @{ 0 = 'Unknown'; 1 = 'Disabled'; 2 = 'Queued'; 3 = 'Ready'; 4 = 'Running' }
$LogonTypes = @{ 0 = 'None'; 1 = 'Password'; 2 = 'S4U'; 3 = 'Interactive'; 4 = 'Group'; 5 = 'ServiceAccount'; 6 = 'InteractiveOrPassword' }

function Get-ScheduledRunning {
    try {
        $t = Get-TaskCom
        if ($t -and $t.State -eq 4) { return $TaskName }
        return $null
    } catch {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($t -and $t.State -eq 'Running') { return $TaskName }
        return $null
    }
}

function Get-RunStatus {
    if (-not $script:Run) { return @{ running = $false; hasRun = $false } }
    $p = $script:Run.Proc
    $running = -not $p.HasExited
    $log = if (Test-Path $script:Run.Log) { Read-Shared $script:Run.Log } else { '' }
    $err = if (Test-Path "$($script:Run.Log).err") { Read-Shared "$($script:Run.Log).err" } else { '' }
    $lines = @($log -split "\r?\n" | Where-Object { $_ -ne '' })
    $prog = $lines | Where-Object { $_ -match '^\[进度\] 第 (\d+) / (\d+) 轮' } | Select-Object -Last 1
    $done = 0; $total = 0
    if ($prog -and $prog -match '第 (\d+) / (\d+) 轮') { $done = [int]$matches[1]; $total = [int]$matches[2] }
    @{
        running      = $running
        hasRun       = $true
        startedStamp = $script:Run.StartedStamp
        elapsed      = [int]((Get-Date) - $script:Run.Started).TotalSeconds
        exitCode     = $(if ($running) { $null } else { $p.ExitCode })
        roundsDone   = $done
        roundsTotal  = $total
        tracing      = [bool]($lines | Where-Object { $_ -match '等待路由追踪' })
        log          = (($lines | Where-Object { $_ -notmatch '^\[进度\]' } | Select-Object -Last 200) -join "`n")
        error        = $err.Trim()
        args         = $script:Run.Args
    }
}

function Start-WebRun($body) {
    if ($script:Run -and -not $script:Run.Proc.HasExited) { return @{ ok = $false; message = '已有一次网页测速正在运行' } }
    $busy = Get-ScheduledRunning
    if ($busy) { return @{ ok = $false; message = "定时任务 $busy 正在运行，请稍后再试（每次约 5~8 分钟）" } }
    $valid = @($RegionInfo.regions | ForEach-Object { $_.code })
    $regs = @($body.regions | Where-Object { $valid -contains $_ })
    $rounds = [int]$body.rounds
    if ($rounds -lt 1 -or $rounds -gt 50) { $rounds = 12 }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Runner`"", '-Rounds', $rounds)
    if ($regs.Count -gt 0) { $argList += @('-Regions', ($regs -join ',')) } else { $argList += @('-Regions', 'none') }
    if ($body.trace) { $argList += '-Trace' }
    $now = Get-Date
    $log = Join-Path $LogDir ('web-run-{0:yyyyMMdd-HHmmss}.log' -f $now)
    $p = Start-Process powershell.exe -ArgumentList $argList -WorkingDirectory $Root -WindowStyle Hidden `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
    $null = $p.Handle   # 先取得句柄，进程结束后才能读到 ExitCode
    $script:Run = @{ Proc = $p; Log = $log; Started = $now; StartedStamp = $now.ToString('yyyy-MM-dd HH:mm')
                     Args = @{ regions = $regs.Count; rounds = $rounds; trace = [bool]$body.trace } }
    @{ ok = $true; startedStamp = $script:Run.StartedStamp }
}

function Stop-WebRun {
    if ($script:Run -and -not $script:Run.Proc.HasExited) {
        $id = $script:Run.Proc.Id
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        Remove-Item $LockFile -ErrorAction SilentlyContinue
        return @{ ok = $true }
    }
    @{ ok = $false; message = '没有正在运行的网页测速' }
}

# ---------- 定时任务管理 ----------
function Format-Time($d) { if (-not $d -or $d.Year -lt 2000) { return '' }; return $d.ToString('yyyy-MM-dd HH:mm') }
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

function Get-ScheduleConfig {
    $c = if (Test-Path $CfgFile) { Import-PowerShellDataFile $CfgFile } else { @{} }
    $s = if ($c.Schedule) { $c.Schedule } else { @{} }
    $times = if ($s.Times) { @($s.Times) } else { @(0..23 | ForEach-Object { '{0:D2}:00' -f $_ }) }
    $delay = if ($null -ne $s.RandomDelayMinutes) { [int]$s.RandomDelayMinutes } else { 5 }
    if (Test-Path $ScheduleOverride) {
        $o = Get-Content $ScheduleOverride -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($o.Times) { $times = @($o.Times) }
        if ($null -ne $o.RandomDelayMinutes) { $delay = [int]$o.RandomDelayMinutes }
    }
    @{ times = $times; delay = $delay; logonType = $(if ($s.LogonType) { $s.LogonType } else { 'Interactive' }); fromWeb = (Test-Path $ScheduleOverride) }
}

function Get-ScheduleInfo {
    $r = @{ taskName = $TaskName; config = (Get-ScheduleConfig); isAdmin = (Test-Admin); installed = $false }
    try { $t = Get-TaskCom } catch { $t = $false }
    if ($t) {
        $d = $t.Definition
        $r.installed  = $true
        $r.state      = $TaskStates[[int]$t.State]
        $r.enabled    = [bool]$t.Enabled
        $r.nextRun    = Format-Time $t.NextRunTime
        $r.lastRun    = Format-Time $t.LastRunTime
        $r.lastResult = $t.LastTaskResult
        $r.times      = @(@(foreach ($tr in $d.Triggers) { ([datetime]$tr.StartBoundary).ToString('HH:mm') }) | Sort-Object)
        $r.logonType  = $LogonTypes[[int]$d.Principal.LogonType]
        $r.samePath   = "$(@($d.Actions)[0].Arguments)".ToLower().Contains($Root.ToLower())
        return $r
    }
    if ($null -eq $t) { return $r }   # COM 正常，任务未安装
    # COM 接口不可用：退回原来的命令
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        $i = Get-ScheduledTaskInfo -TaskName $TaskName
        $r.installed  = $true
        $r.state      = "$($t.State)"
        $r.enabled    = ("$($t.State)" -ne 'Disabled')
        $r.nextRun    = Format-Time $i.NextRunTime
        $r.lastRun    = Format-Time $i.LastRunTime
        $r.lastResult = $i.LastTaskResult
        $r.times      = @($t.Triggers | ForEach-Object { ([datetime]$_.StartBoundary).ToString('HH:mm') } | Sort-Object)
        $r.logonType  = "$($t.Principal.LogonType)"
        $r.samePath   = "$($t.Actions[0].Arguments)".ToLower().Contains($Root.ToLower())
    }
    $r
}

function Save-Schedule($body) {
    $times = @($body.times | Where-Object { $_ -match '^\d{2}:\d{2}$' } | Sort-Object -Unique)
    if (-not $times.Count) { return @{ ok = $false; message = '请至少选择一个时间点' } }
    $delay = [int]$body.delay; if ($delay -lt 0 -or $delay -gt 59) { $delay = 5 }
    @{ Times = $times; RandomDelayMinutes = $delay } | ConvertTo-Json | Set-Content $ScheduleOverride -Encoding UTF8
    try { $out = (& $InstallScript *>&1 | Out-String).Trim() } catch { $out = "$($_.Exception.Message)" }
    if ($out -match 'Access is denied|拒绝访问|0x80070005') { $out += "`n权限不足：请右键「启动测速网站.cmd」→「以管理员身份运行」后再保存" }
    try { $t = Get-TaskCom } catch { $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
    $ok = [bool]$t -and ($out -match '已安装定时任务')
    if ($ok -and $body.enabled -eq $false) { $null = Set-ScheduleState 'disable' }
    @{ ok = $ok; output = $out; message = $(if ($ok) { '已保存并安装' } else { '安装失败，请查看输出' }) }
}

function Set-ScheduleState([string]$action) {
    if ($action -notin 'enable', 'disable', 'runnow', 'uninstall') { return @{ ok = $false; message = '未知操作' } }
    if ($action -eq 'runnow' -and $script:Run -and -not $script:Run.Proc.HasExited) { return @{ ok = $false; message = '网页测速正在运行，请等它结束' } }
    try {
        $com = $true
        try { $t = Get-TaskCom } catch { $com = $false }
        if ($com) {
            if (-not $t) { return @{ ok = $false; message = '定时任务未安装' } }
            switch ($action) {
                'enable'    { $t.Enabled = $true }
                'disable'   { $t.Enabled = $false }
                'runnow'    { $null = $t.Run($null) }
                'uninstall' { $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $svc.GetFolder('\').DeleteTask($TaskName, 0) }
            }
        } else {   # COM 接口不可用：退回原来的命令
            switch ($action) {
                'enable'    { Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
                'disable'   { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
                'runnow'    { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
                'uninstall' { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop }
            }
        }
        @{ ok = $true }
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'Access is denied|拒绝访问|0x80070005') { $m = '权限不足：请右键「启动测速网站.cmd」→「以管理员身份运行」后再操作' }
        @{ ok = $false; message = $m }
    }
}

# ---------- 数据管理 ----------
function Get-BusyReason {
    if ($script:Run -and -not $script:Run.Proc.HasExited) { return '网页测速正在运行' }
    if (Get-ScheduledRunning) { return '定时任务正在运行' }
    if (Test-Path $LockFile) {
        $lp = (Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1) -as [int]
        if ($lp -and (Get-Process -Id $lp -ErrorAction SilentlyContinue)) { return '有测速正在运行' }
    }
    $null
}
function Read-Rows { if (Test-Path $CsvPath) { @((Read-Shared $CsvPath) | ConvertFrom-Csv) } else { @() } }
function Write-Rows($rows) {
    $enc = New-Object Text.UTF8Encoding($true)
    $lines = if (@($rows).Count) { $rows | Select-Object -Property $Columns | ConvertTo-Csv -NoTypeInformation } else { @((($Columns | ForEach-Object { '"' + $_ + '"' }) -join ',')) }
    [IO.File]::WriteAllLines($CsvPath, [string[]]$lines, $enc)
}
function Backup-Csv {
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    $bk = Join-Path $BackupDir ('latency-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    Copy-Item $CsvPath $bk
    Get-ChildItem $BackupDir -Filter 'latency-*.csv' | Sort-Object Name -Descending | Select-Object -Skip 10 | Remove-Item -ErrorAction SilentlyContinue
    Split-Path $bk -Leaf
}

function Get-DataStats {
    $rows = Read-Rows
    $stamps = @($rows | ForEach-Object { $_.时间 } | Sort-Object -Unique)
    $logs = @(Get-ChildItem $LogDir -File -ErrorAction SilentlyContinue)
    $bks = @(Get-ChildItem $BackupDir -Filter 'latency-*.csv' -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
             ForEach-Object {
                 $bt = [datetime]::ParseExact($_.Name.Substring(8, 15), 'yyyyMMdd-HHmmss', $null)   # 备份时刻取自文件名
                 @{ name = $_.Name; sizeKB = [math]::Round($_.Length / 1KB); time = $bt.ToString('yyyy-MM-dd HH:mm:ss')
                    rows = [math]::Max(0, @([IO.File]::ReadAllLines($_.FullName) | Where-Object { $_ }).Count - 1) } })
    @{
        rows = $rows.Count; runs = $stamps.Count
        first = $(if ($stamps.Count) { $stamps[0] } else { '' }); last = $(if ($stamps.Count) { $stamps[-1] } else { '' })
        stamps = @($stamps | Sort-Object -Descending | Select-Object -First 500)
        sizeKB = $(if (Test-Path $CsvPath) { [math]::Round((Get-Item $CsvPath).Length / 1KB) } else { 0 })
        logs = $logs.Count; logsKB = [math]::Round((($logs | Measure-Object Length -Sum).Sum) / 1KB)
        backups = $bks
    }
}

function Invoke-Clean($body) {
    $busy = Get-BusyReason; if ($busy) { return @{ ok = $false; message = "$busy，请稍后再清理" } }
    $rows = Read-Rows; $before = $rows.Count
    switch ("$($body.mode)") {
        'before' { $days = [int]$body.days; if ($days -lt 1) { return @{ ok = $false; message = '天数至少为 1' } }
                   $cut = (Get-Date).AddDays(-$days).ToString('yyyy-MM-dd HH:mm'); $keep = @($rows | Where-Object { $_.时间 -ge $cut }) }
        'run'    { $keep = @($rows | Where-Object { $_.时间 -ne "$($body.stamp)" }) }
        'region' { $keep = @($rows | Where-Object { $_.区域 -ne "$($body.code)" }) }
        'all'    { $keep = @() }
        'logs'   { $keep = $rows }
        default  { return @{ ok = $false; message = '未知的清理方式' } }
    }
    $removed = $before - $keep.Count
    $bk = ''
    if ($removed -gt 0) { $bk = Backup-Csv; Write-Rows $keep }
    $logsRemoved = 0
    if ($body.cleanLogs -and [int]$body.logDays -ge 1) {
        $cutL = (Get-Date).AddDays(-[int]$body.logDays)
        Get-ChildItem $LogDir -File | Where-Object { $_.LastWriteTime -lt $cutL } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue; $logsRemoved++ }
    }
    @{ ok = $true; removed = $removed; remaining = $keep.Count; backup = $bk; logsRemoved = $logsRemoved }
}

function Invoke-Restore($body) {
    $busy = Get-BusyReason; if ($busy) { return @{ ok = $false; message = "$busy，请稍后再恢复" } }
    $name = "$($body.name)"
    if ($name -notmatch '^latency-\d{8}-\d{6}\.csv$') { return @{ ok = $false; message = '备份文件名无效' } }
    $src = Join-Path $BackupDir $name
    if (-not (Test-Path $src)) { return @{ ok = $false; message = '备份不存在' } }
    $bk = if (Test-Path $CsvPath) { Backup-Csv } else { '' }
    Copy-Item $src $CsvPath -Force
    @{ ok = $true; restored = $name; backupOfCurrent = $bk; rows = (Read-Rows).Count }
}

$Mime = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon' }

function Handle($ctx) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    if ($path -like '/api/*') {
        if ($req.Headers['X-Token'] -ne $Token) { Send-Json $ctx @{ error = 'forbidden' } 403; return }
        switch ("$($req.HttpMethod) $path") {
            'GET /api/info'   { Send-Json $ctx @{ label = $Label; regions = $RegionInfo.regions; references = $RegionInfo.references; referenceNames = $RegionInfo.referenceNames; csvExists = (Test-Path $CsvPath) }; return }
            'GET /api/csv'    { $t = if (Test-Path $CsvPath) { Read-Shared $CsvPath } else { '' }; Send-Text $ctx 200 'text/csv; charset=utf-8' $t; return }
            'GET /api/status' { Send-Json $ctx (Get-RunStatus); return }
            'POST /api/run'   { Send-Json $ctx (Start-WebRun (Read-Body $req)); return }
            'POST /api/stop'  { Send-Json $ctx (Stop-WebRun); return }
            'GET /api/schedule'          { Send-Json $ctx (Get-ScheduleInfo); return }
            'POST /api/schedule/save'    { Send-Json $ctx (Save-Schedule (Read-Body $req)); return }
            'POST /api/schedule/action'  { Send-Json $ctx (Set-ScheduleState "$((Read-Body $req).action)"); return }
            'GET /api/data/stats'        { Send-Json $ctx (Get-DataStats); return }
            'POST /api/data/clean'       { Send-Json $ctx (Invoke-Clean (Read-Body $req)); return }
            'POST /api/data/restore'     { Send-Json $ctx (Invoke-Restore (Read-Body $req)); return }
            default           { Send-Json $ctx @{ error = 'not found' } 404; return }
        }
    }
    if ($path -eq '/' -or $path -eq '/index.html') {
        $html = [IO.File]::ReadAllText((Join-Path $WebDir 'index.html'), [Text.Encoding]::UTF8).Replace('__TOKEN__', $Token)
        Send-Text $ctx 200 'text/html; charset=utf-8' $html; return
    }
    $rel = $path.TrimStart('/')
    if ($rel -match '\.\.' -or $rel -match '[:\\]') { Send-Text $ctx 400 'text/plain' 'bad path'; return }
    $file = Join-Path $WebDir $rel
    if (Test-Path $file -PathType Leaf) {
        $ext = [IO.Path]::GetExtension($file).ToLower()
        $ct = if ($Mime.ContainsKey($ext)) { $Mime[$ext] } else { 'application/octet-stream' }
        Send-Bytes $ctx 200 $ct ([IO.File]::ReadAllBytes($file)); return
    }
    Send-Text $ctx 404 'text/plain' 'not found'
}

# ---------- 启动 ----------
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch {
    Write-Host "无法在端口 $Port 启动：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "可能已经有一个测速网站在运行，直接在浏览器打开 http://localhost:$Port/ 试试。"
    if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }
    exit 1
}
$url = "http://localhost:$Port/"
$host.UI.RawUI.WindowTitle = "测速网站 - $Label - $url"
Write-Host "测速网站已启动：$url  （$Label）" -ForegroundColor Green
Write-Host "只能在本机访问。关闭本窗口即停止网站（定时测速不受影响）。"
if (-not $NoBrowser) { Start-Process $url }

while ($listener.IsListening) {
    try { $ctx = $listener.GetContext() } catch { break }
    try { Handle $ctx } catch {
        Write-Host ("[{0:HH:mm:ss}] 请求出错 {1}: {2}" -f (Get-Date), $ctx.Request.Url.AbsolutePath, $_.Exception.Message) -ForegroundColor Yellow
        try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch {}
    }
}
