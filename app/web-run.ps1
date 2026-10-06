<#
  由测速网站（dashboard.ps1）在后台调用：执行一次测速，输出 UTF-8 文本供网页读取。
  运行期间创建 data\run.lock，定时任务看到它会跳过本次，避免两次测速同时进行互相干扰。
#>
param(
    [string]$Regions,
    [int]$Rounds = 12,
    [switch]$Trace
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$ProgressPreference = 'SilentlyContinue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lock = Join-Path (Split-Path -Parent $Here) 'data\run.lock'
Set-Content -Path $Lock -Value $PID -Encoding ASCII
$env:LATENCY_PROGRESS = '1'
try {
    $p = @{ Rounds = $Rounds }
    if ($Regions) { $p.Regions = $Regions }
    if ($Trace)   { $p.Trace = $true }
    & (Join-Path $Here 'latency.ps1') @p
} finally {
    Remove-Item $Lock -ErrorAction SilentlyContinue
}
