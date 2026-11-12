# Codex Usage Tracker

A small, local-only Windows watcher that records the latest Codex usage limits for the active signed-in ChatGPT account.

## What it records

The tracker reads the local Codex app-server account and rate-limit APIs. It saves one latest row per account in `%LOCALAPPDATA%\CodexUsageTracker\accounts.csv`, including:

- Account email and plan type
- First observed login time and snapshot time, in UTC and local time
- Used and remaining percentages for the 5-hour and weekly limits
- Reset times for both limits
- Available earned resets and their soonest expiry

The tracker writes diagnostics to `%LOCALAPPDATA%\CodexUsageTracker\tracker.log`. The CSV and log stay on this computer; the tracker does not send them to a service. It does not store access tokens, change Codex settings, or consume earned resets.

## Requirements

- Windows with Windows PowerShell 5.1
- The Codex desktop app or Codex CLI installed
- A signed-in ChatGPT account available to Codex

## Install and run

Open PowerShell in this folder and run the installer once:

```powershell
.\install.ps1
```

The installer copies the watcher into `%LOCALAPPDATA%\CodexUsageTracker`, adds a hidden shortcut to your per-user Windows Startup folder, and starts the watcher. Administrator privileges are not needed. The watcher waits for `ChatGPT.exe` or `codex.exe`, then refreshes the active account every 60 seconds.

To take one snapshot manually:

```powershell
.\codex_usage_tracker.ps1 -Once
```

To run a foreground watcher with a custom polling interval:

```powershell
.\codex_usage_tracker.ps1 -Watch -PollSeconds 60
```

The script also accepts `-DataFile` and `-LogFile` to use alternate output paths.

## Remove auto-start

Run:

```powershell
.\uninstall.ps1
```

This removes the startup shortcut and stops the watcher. It intentionally leaves the installed script, CSV, and log in place; remove `%LOCALAPPDATA%\CodexUsageTracker` yourself if you also want to delete those local records.

## Create a personal Codex usage plugin

The tracker writes snapshots; it does not include a plugin. You can ask Codex to create a personal, local plugin that reads the CSV and summarizes the latest snapshot. “Live” means the plugin rereads the latest saved file when you call it. While the watcher is running, that snapshot is refreshed about once a minute; the plugin does not switch accounts or stream updates by itself.

Because the CSV contains account usage, keep this plugin local. Use a local stdio MCP server and a personal marketplace for testing. Do not upload the CSV, expose a local server through a public endpoint, or submit a plugin that reads your local file to the public plugin directory. A local MCP plugin requires desktop execution; public-directory submission has additional eligibility and review requirements. See the [plugin packaging guide](https://developers.openai.com/plugins/build/plugins) and [desktop-only plugin guide](https://developers.openai.com/plugins/deploy/desktop-only).

### Suggested build prompt

In Codex desktop, use `$plugin-creator` with a prompt like this:

```text
$plugin-creator Build a personal Windows-only Codex desktop plugin named Codex Usage Summary and add it to a personal local marketplace for testing. Include a local stdio MCP server with one read-only tool named get_usage_summary. On every call, reread %LOCALAPPDATA%\CodexUsageTracker\accounts.csv. Do not make network calls, read Codex auth files, accept an arbitrary file path from the model, expose a generic filesystem tool, write files, or switch accounts. Validate the expected CSV headers and timestamps. Summarize only snapshots no older than 10 minutes; if no account has fresh data, say there is no reliable recommendation. Return five-hour and weekly used/remaining percentages, reset times in local time, snapshot age, and available earned-reset count. Mask account emails by default as Account 1, Account 2, and so on. Recommend the fresh account with the highest minimum of its five-hour and weekly remaining percentages; explain the score and do not recommend an account when required values are missing. Add tests with synthetic CSV rows kept outside the repository and verify that no raw emails or data from other files are returned. Keep all plugin files in a separate plugin folder and do not change the tracker scripts. If local stdio execution or the personal marketplace is unavailable, explain the limitation and stop; do not switch to a hosted server or upload account data.
```

After Codex creates the plugin, review its MCP command, file path, tool schema, and tests. Keep the server implementation limited to the one CSV path and expose no generic file or command tools. A local MCP process runs with your Windows account's permissions; plugin instructions and manifests do not sandbox its file access, so inspect the server code and dependencies before enabling it. Add the generated local marketplace with `codex plugin marketplace add <path-to-marketplace-root>` if it was not registered for you, restart the Codex desktop app, and install the plugin from the Plugins Directory.

### Suggested validation prompt

Once the local plugin is installed, try:

```text
Use Codex Usage Summary to show the latest usage snapshot and recommend which account I should use next. Call the plugin tool instead of opening files directly. Show each account's masked label, five-hour and weekly remaining percentages, reset times in local time, snapshot age, and recommendation score. Recommend only from snapshots no older than 10 minutes. If all snapshots are stale or missing required values, say that no reliable recommendation is available. Do not switch accounts.
```

The recommendation is advisory: it ranks fresh rows by the lower of the two remaining percentages and never changes the active account.

## Public repository and local data

This repository contains tracker source and documentation only. It does not contain a usage CSV, tracker log, account email, authentication file, or token. The tracker stores runtime data under `%LOCALAPPDATA%\CodexUsageTracker`, outside this repository. The `.gitignore` excludes CSV files, logs, and local environment files so accidental local copies are not committed. Review `git status` before publishing future changes.

## Notes

- Usage is read through Codex app-server JSON-RPC methods `account/read` and `account/rateLimits/read`.
- Login time is the tracker's observation time, within one poll interval of the actual sign-in or account switch.
- If a sign-in change in the desktop app is not reflected in Codex's local auth state, the watcher cannot observe that switch.
- Reset-credit expiry details depend on the fields returned by the installed Codex app-server version.
