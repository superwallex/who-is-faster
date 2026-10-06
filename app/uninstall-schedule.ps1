# 卸载定时任务（只删除任务计划中的条目，脚本和测速数据都保留）
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$CfgFile = Join-Path $Root 'config\config.psd1'
$cfg = if (Test-Path $CfgFile) { Import-PowerShellDataFile $CfgFile } else { @{} }
$TaskName = if ($cfg.Schedule -and $cfg.Schedule.TaskName) { $cfg.Schedule.TaskName } else { 'CloudLatencyProbe' }
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已卸载定时任务: $TaskName（脚本和测速数据都保留）"
} else {
    Write-Host "未找到定时任务: $TaskName"
}
