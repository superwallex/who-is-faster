<#
  安装 / 更新 Windows 定时任务。设置来自 config\config.psd1 的 Schedule 项：
    TaskName            任务名（默认 CloudLatencyProbe）
    Times               每天运行的时间点（默认每小时整点）
    RandomDelayMinutes  每次随机推迟 0~N 分钟（默认 5）
    LogonType           Interactive = 只在你登录 Windows 时运行（默认，无需管理员）
                        S4U         = 不登录也运行、不保存密码（适合服务器，需以管理员身份运行本脚本）
  在测速网站"设置"页保存的时间点和随机推迟写在 config\schedule.json，优先于 config.psd1。
  修改配置后重新运行本脚本（tools\安装定时任务.cmd）即可更新。
#>
$ErrorActionPreference = 'Stop'
$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root   = Split-Path -Parent $Here
$Runner = Join-Path $Here 'scheduled-run.ps1'
$CfgFile = Join-Path $Root 'config\config.psd1'
$cfg = if (Test-Path $CfgFile) { Import-PowerShellDataFile $CfgFile } else { @{} }
$s = if ($cfg.Schedule) { $cfg.Schedule } else { @{} }

$TaskName = if ($s.TaskName) { $s.TaskName } else { 'CloudLatencyProbe' }
$Times    = if ($s.Times) { @($s.Times) } else { 0..23 | ForEach-Object { '{0:D2}:00' -f $_ } }
$Delay    = if ($null -ne $s.RandomDelayMinutes) { [int]$s.RandomDelayMinutes } else { 5 }
$Logon    = if ($s.LogonType) { $s.LogonType } else { 'Interactive' }
$Override = Join-Path $Root 'config\schedule.json'
if (Test-Path $Override) {
    $o = Get-Content $Override -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($o.Times) { $Times = @($o.Times) }
    if ($null -ne $o.RandomDelayMinutes) { $Delay = [int]$o.RandomDelayMinutes }
}

if ($Logon -eq 'S4U') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Host "LogonType = S4U 需要管理员权限：请右键 tools\安装定时任务.cmd →「以管理员身份运行」。" -ForegroundColor Yellow; exit 1 }
}
$tz = Get-TimeZone
Write-Host ("本机时区: {0}（UTC{1}{2}）" -f $tz.Id, $(if ($tz.BaseUtcOffset -ge [TimeSpan]::Zero) { '+' } else { '' }), $tz.BaseUtcOffset)

# 任务计划的"起始位置"最长约 248 个字符，超长会导致任务无法启动；脚本内部都用绝对路径，超长时直接不设
$wd = if ($Root.Length -lt 240) { @{ WorkingDirectory = $Root } } else { @{} }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ("-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"{0}`"" -f $Runner) @wd
$triggers = foreach ($t in $Times) {
    $tr = New-ScheduledTaskTrigger -Daily -At $t
    if ($Delay -gt 0) { $tr.RandomDelay = 'PT{0}M' -f $Delay }
    $tr
}
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType $Logon -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
    -Description "云区域定时测速（$Root）" -Force | Out-Null

$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "已安装定时任务: $TaskName（运行身份 $env:USERNAME，方式 $Logon）" -ForegroundColor Green
Write-Host ("每天运行 {0} 次：{1}（每次随机推迟 0~{2} 分钟；错过的会在开机/唤醒后补跑）" -f @($Times).Count, ($Times -join ' '), $Delay)
Write-Host ("下次运行: {0}" -f $info.NextRunTime)
if ($Logon -eq 'Interactive') { Write-Host "说明：只在你登录 Windows 时运行（锁屏也会运行）。" }
