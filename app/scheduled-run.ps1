<#
  由 Windows 任务计划调用：静默执行一次"测速 + 路径"，输出追加到 data\logs\yyyy-MM.log
  也可以手动运行（tools\立即测速一次.cmd）来模拟一次定时任务。
#>
$ErrorActionPreference = 'Continue'
$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Data   = Join-Path (Split-Path -Parent $Here) 'data'
$LogDir = Join-Path $Data 'logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null
$Log = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM') + '.log')
$ProgressPreference = 'SilentlyContinue'

# 测速网站正在测速时跳过本次，避免两次测速同时进行互相干扰
$Lock = Join-Path $Data 'run.lock'
if (Test-Path $Lock) {
    $lockPid = (Get-Content $Lock -ErrorAction SilentlyContinue | Select-Object -First 1) -as [int]
    if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
        Add-Content -Path $Log -Value ("===== {0:yyyy-MM-dd HH:mm:ss} 跳过：测速网站正在测速（进程 {1}）=====`n" -f (Get-Date), $lockPid) -Encoding UTF8
        exit 0
    }
    Remove-Item $Lock -ErrorAction SilentlyContinue   # 残留的锁文件
}

Start-Transcript -Path $Log -Append | Out-Null
try {
    Write-Host ("===== 定时测速开始 {0:yyyy-MM-dd HH:mm:ss} =====" -f (Get-Date))
    # 测哪些区域、是否追踪路径：测速网站"定时任务"页保存在 config\schedule.json；
    # 没保存过时不传 -Regions（按 config.psd1 的 Regions，留空 = 全部区域），并追踪路径
    $runArgs = @{ Trace = $true }
    $override = Join-Path (Split-Path -Parent $Here) 'config\schedule.json'
    if (Test-Path $override) {
        try {
            $o = Get-Content $override -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($o.Regions) { $runArgs.Regions = @($o.Regions) }
            if ($null -ne $o.Trace -and -not $o.Trace) { $runArgs.Remove('Trace') }
        } catch { Write-Host "读取 config\schedule.json 失败，按默认设置测速：$_" }
    }
    & (Join-Path $Here 'latency.ps1') @runArgs
    Write-Host ("===== 定时测速结束 {0:yyyy-MM-dd HH:mm:ss} =====`n" -f (Get-Date))
} catch {
    Write-Host "运行出错: $_"
} finally {
    Stop-Transcript | Out-Null
}
