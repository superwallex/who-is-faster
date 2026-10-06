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
    & (Join-Path $Here 'latency.ps1') -Trace
    Write-Host ("===== 定时测速结束 {0:yyyy-MM-dd HH:mm:ss} =====`n" -f (Get-Date))
} catch {
    Write-Host "运行出错: $_"
} finally {
    Stop-Transcript | Out-Null
}
