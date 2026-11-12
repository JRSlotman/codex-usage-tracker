[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$Once,
    [ValidateRange(15, 3600)]
    [int]$PollSeconds = 60,
    [string]$DataFile = (Join-Path $env:LOCALAPPDATA 'CodexUsageTracker\accounts.csv'),
    [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'CodexUsageTracker\tracker.log')
)

$ErrorActionPreference = 'Stop'

function Write-TrackerLog {
    param([string]$Message)
    try {
        $parent = Split-Path -Parent $LogFile
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $line = '{0} {1}' -f [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz'), $Message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Get-CodexExecutable {
    $command = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and (Test-Path -LiteralPath $command.Source)) { return $command.Source }

    $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $binRoot) {
        foreach ($directory in (Get-ChildItem -LiteralPath $binRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
            $candidate = Join-Path $directory.FullName 'codex.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }

    $extensionRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
    if (Test-Path -LiteralPath $extensionRoot) {
        foreach ($directory in (Get-ChildItem -Path (Join-Path $extensionRoot 'openai.chatgpt-*') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
            $candidate = Join-Path $directory.FullName 'bin\windows-x86_64\codex.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }

    throw 'Could not locate codex.exe. Install the Codex app or CLI, then rerun the tracker.'
}

function Send-RpcAndRead {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$RequestId,
        [string]$Json
    )
    $Process.StandardInput.WriteLine($Json)
    $Process.StandardInput.Flush()
    while ($true) {
        $readTask = $Process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait(30000)) { throw "Timed out waiting for app-server response $RequestId." }
        $line = $readTask.Result
        if ($null -eq $line) { throw "Codex app-server closed before response $RequestId." }
        try { $message = ConvertFrom-Json -InputObject $line } catch { continue }
        if ($null -ne $message.id -and [int]$message.id -eq $RequestId) {
            if ($message.error) {
                $messageText = if ($message.error.message) { $message.error.message } else { 'RPC request failed.' }
                throw "Codex app-server RPC $RequestId failed: $messageText"
            }
            return $message.result
        }
    }
}

function Invoke-CodexUsageRead {
    $executable = Get-CodexExecutable
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = 'app-server --listen stdio://'
    $startInfo.WorkingDirectory = $env:USERPROFILE
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Could not start codex app-server.' }
    $stderrTask = $process.StandardError.ReadToEndAsync()
    try {
        $null = Send-RpcAndRead -Process $process -RequestId 1 -Json '{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex-usage-tracker","title":"Codex Usage Tracker","version":"1.0.0"}}}'
        $process.StandardInput.WriteLine('{"method":"initialized","params":{}}')
        $process.StandardInput.Flush()
        $accountResult = Send-RpcAndRead -Process $process -RequestId 2 -Json '{"method":"account/read","id":2,"params":{"refreshToken":false}}'
        if (-not $accountResult.account) { return [PSCustomObject]@{ Authenticated = $false } }
        if ($accountResult.account.type -ne 'chatgpt') { throw "Active Codex auth type is '$($accountResult.account.type)', not a ChatGPT plan account." }
        $limitsResult = Send-RpcAndRead -Process $process -RequestId 3 -Json '{"method":"account/rateLimits/read","id":3}'
        return [PSCustomObject]@{
            Authenticated = $true
            Account = $accountResult.account
            Limits = $limitsResult
        }
    } finally {
        if (-not $process.HasExited) {
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(3000)) { $process.Kill() }
        }
        $process.Dispose()
    }
}

function Convert-UnixTime {
    param([object]$Seconds, [switch]$Local)
    if ($null -eq $Seconds -or [string]$Seconds -eq '') { return $null }
    try {
        $value = [DateTimeOffset]::FromUnixTimeSeconds([long]$Seconds)
        if ($Local) { return $value.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') }
        return $value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    } catch { return $null }
}

function Get-UsageWindows {
    param([object]$Limits)
    $windows = @()
    if ($Limits.rateLimitsByLimitId) {
        foreach ($property in $Limits.rateLimitsByLimitId.PSObject.Properties) {
            $bucket = $property.Value
            foreach ($slot in @('primary', 'secondary')) {
                $window = $bucket.$slot
                if ($window -and $null -ne $window.windowDurationMins) {
                    $limitId = if ($bucket.limitId) { [string]$bucket.limitId } else { [string]$property.Name }
                    $windows += [PSCustomObject]@{ LimitId = $limitId; Window = $window }
                }
            }
        }
    } elseif ($Limits.rateLimits) {
        foreach ($slot in @('primary', 'secondary')) {
            $window = $Limits.rateLimits.$slot
            if ($window -and $null -ne $window.windowDurationMins) {
                $windows += [PSCustomObject]@{ LimitId = [string]$Limits.rateLimits.limitId; Window = $window }
            }
        }
    }
    return $windows
}

function Select-UsageWindow {
    param([object[]]$Windows, [int]$DurationMinutes)
    $matchingWindows = @($Windows | Where-Object { [int]$_.Window.windowDurationMins -eq $DurationMinutes })
    if ($matchingWindows.Count -eq 0) { return $null }
    $codexMatch = $matchingWindows | Where-Object { $_.LimitId -eq 'codex' } | Select-Object -First 1
    if ($codexMatch) { return $codexMatch }
    return $matchingWindows[0]
}

function Convert-UsageWindow {
    param([object]$Selected)
    if (-not $Selected) {
        return [PSCustomObject]@{ UsedPercent = $null; RemainingPercent = $null; ResetAtUtc = $null; ResetAtLocal = $null }
    }
    $used = $null
    $remaining = $null
    if ($null -ne $Selected.Window.usedPercent) {
        $used = [Math]::Round([Math]::Max(0, [Math]::Min(100, [double]$Selected.Window.usedPercent)), 1)
        $remaining = [Math]::Round(100 - $used, 1)
    }
    return [PSCustomObject]@{
        UsedPercent = $used
        RemainingPercent = $remaining
        ResetAtUtc = Convert-UnixTime -Seconds $Selected.Window.resetsAt
        ResetAtLocal = Convert-UnixTime -Seconds $Selected.Window.resetsAt -Local
    }
}

function Get-UsageRow {
    param([object]$ReadResult)
    $account = $ReadResult.Account
    $email = [string]$account.email
    if (-not $email) { throw 'The signed-in account did not provide an email; no row was written.' }

    $windows = Get-UsageWindows -Limits $ReadResult.Limits
    $fiveHour = Convert-UsageWindow -Selected (Select-UsageWindow -Windows $windows -DurationMinutes 300)
    $weekly = Convert-UsageWindow -Selected (Select-UsageWindow -Windows $windows -DurationMinutes 10080)

    $resetBlock = $ReadResult.Limits.rateLimitResetCredits
    $resetCount = $null
    if ($null -ne $resetBlock -and $null -ne $resetBlock.availableCount) { $resetCount = [int]$resetBlock.availableCount }
    $expiryRows = @()
    foreach ($credit in @($resetBlock.credits)) {
        if (-not $credit) { continue }
        if ($credit.status -and $credit.status -ne 'available') { continue }
        if ($null -ne $credit.expiresAt) {
            $expiryRows += [PSCustomObject]@{
                Epoch = [long]$credit.expiresAt
                Local = Convert-UnixTime -Seconds $credit.expiresAt -Local
                Utc = Convert-UnixTime -Seconds $credit.expiresAt
            }
        }
    }
    $expiryRows = @($expiryRows | Sort-Object Epoch)
    $soonest = if ($expiryRows.Count -gt 0) { $expiryRows[0] } else { $null }
    $now = [DateTimeOffset]::Now
    return [PSCustomObject][ordered]@{
        account_key = $email.Trim().ToLowerInvariant()
        account_email = $email
        plan_type = [string]$account.planType
        login_time_utc = $null
        login_time_local = $null
        captured_at_utc = $now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        captured_at_local = $now.ToString('yyyy-MM-dd HH:mm:ss zzz')
        five_hour_used_percent = $fiveHour.UsedPercent
        five_hour_remaining_percent = $fiveHour.RemainingPercent
        five_hour_reset_at_utc = $fiveHour.ResetAtUtc
        five_hour_reset_at_local = $fiveHour.ResetAtLocal
        weekly_used_percent = $weekly.UsedPercent
        weekly_remaining_percent = $weekly.RemainingPercent
        weekly_reset_at_utc = $weekly.ResetAtUtc
        weekly_reset_at_local = $weekly.ResetAtLocal
        available_reset_count = $resetCount
        soonest_reset_expiry_utc = if ($soonest) { $soonest.Utc } else { $null }
        soonest_reset_expiry_local = if ($soonest) { $soonest.Local } else { $null }
        all_reset_expiries_local = ($expiryRows | ForEach-Object { $_.Local }) -join ' | '
    }
}

function Save-UsageRow {
    param([object]$Row, [bool]$NewLogin)
    $parent = Split-Path -Parent $DataFile
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $existingRows = @()
    if (Test-Path -LiteralPath $DataFile) { $existingRows = @(Import-Csv -LiteralPath $DataFile) }
    $prior = $existingRows | Where-Object { $_.account_key -ieq $Row.account_key } | Select-Object -First 1
    $now = [DateTimeOffset]::Now
    if ($NewLogin -or -not $prior -or -not $prior.login_time_utc) {
        $Row.login_time_utc = $now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $Row.login_time_local = $now.ToString('yyyy-MM-dd HH:mm:ss zzz')
    } else {
        $Row.login_time_utc = $prior.login_time_utc
        $Row.login_time_local = $prior.login_time_local
    }
    $retainedRows = @($existingRows | Where-Object { $_.account_key -ine $Row.account_key })
    @($retainedRows) + @($Row) | Export-Csv -LiteralPath $DataFile -NoTypeInformation -Encoding UTF8
}

function Test-CodexAppRunning {
    return (@(Get-Process -Name @('ChatGPT', 'codex') -ErrorAction SilentlyContinue).Count -gt 0)
}

function Invoke-Capture {
    param([bool]$NewLogin, [string]$PreviousAccountKey)
    $readResult = Invoke-CodexUsageRead
    if (-not $readResult.Authenticated) { return [PSCustomObject]@{ Authenticated = $false; AccountKey = $null } }
    $row = Get-UsageRow -ReadResult $readResult
    $accountChanged = $PreviousAccountKey -and $row.account_key -ne $PreviousAccountKey
    Save-UsageRow -Row $row -NewLogin ($NewLogin -or $accountChanged)
    return [PSCustomObject]@{ Authenticated = $true; AccountKey = $row.account_key; Email = $row.account_email; CapturedAt = $row.captured_at_local }
}

if ($Watch) {
    $wasRunning = $false
    $previousAccount = $null
    while ($true) {
        $appRunning = Test-CodexAppRunning
        if ($appRunning) {
            try {
                $capture = Invoke-Capture -NewLogin ((-not $wasRunning) -or (-not $previousAccount)) -PreviousAccountKey $previousAccount
                if ($capture.Authenticated) {
                    $previousAccount = $capture.AccountKey
                } else {
                    $previousAccount = $null
                }
            } catch {
                Write-TrackerLog $_.Exception.Message
            }
        } else {
            $previousAccount = $null
        }
        $wasRunning = $appRunning
        Start-Sleep -Seconds $PollSeconds
    }
} else {
    try {
        $capture = Invoke-Capture -NewLogin $false
        if ($capture.Authenticated) { Write-Output ('Updated {0} at {1}.' -f $capture.Email, $capture.CapturedAt) }
        else { Write-Output 'No ChatGPT account is signed in to Codex.' }
    } catch {
        Write-TrackerLog $_.Exception.Message
        throw
    }
}
