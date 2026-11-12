[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'Codex Usage Tracker'
$installDirectory = Join-Path $env:LOCALAPPDATA 'CodexUsageTracker'
$installedRunner = Join-Path $installDirectory 'codex_usage_tracker.ps1'
$startupShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Codex Usage Tracker.lnk'

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
if (Test-Path -LiteralPath $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut
}

$runningWatchers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*$installedRunner*" -and $_.CommandLine -match '\s-Watch(?:\s|$)'
})
foreach ($watcher in $runningWatchers) {
    Stop-Process -Id $watcher.ProcessId -ErrorAction SilentlyContinue
}
Write-Output 'Removed the local auto-start entry and stopped the watcher. The CSV and installed script were kept.'
