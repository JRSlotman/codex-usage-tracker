[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'Codex Usage Tracker'
$installDirectory = Join-Path $env:LOCALAPPDATA 'CodexUsageTracker'
$sourceRunner = Join-Path $PSScriptRoot 'codex_usage_tracker.ps1'
$installedRunner = Join-Path $installDirectory 'codex_usage_tracker.ps1'
$startupDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$shortcutPath = Join-Path $startupDirectory 'Codex Usage Tracker.lnk'

if (-not (Test-Path -LiteralPath $sourceRunner)) { throw "Tracker script not found: $sourceRunner" }
New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $startupDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceRunner -Destination $installedRunner -Force

# Remove the earlier Task Scheduler registration if an earlier install created it.
$oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($oldTask) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Watch' -f $installedRunner
$launcher = New-Object -ComObject WScript.Shell
$shortcut = $launcher.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $env:USERPROFILE
$shortcut.WindowStyle = 7
$shortcut.Description = 'Records the latest local Codex usage limits for each signed-in account.'
$shortcut.Save()

$launchCommand = '"{0}" {1}' -f $powershell, $arguments
$null = $launcher.Run($launchCommand, 0, $false)
Start-Sleep -Seconds 2
$runningWatchers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*$installedRunner*" -and $_.CommandLine -match '\s-Watch(?:\s|$)'
})
if ($runningWatchers.Count -eq 0) {
    throw "The startup shortcut was saved, but the watcher did not stay running. Check $installDirectory\tracker.log."
}
Write-Output "Installed and started the hidden '$shortcutPath' startup shortcut. It waits for ChatGPT or Codex to run, then updates $installDirectory\accounts.csv."
