# turn-toast

A GitHub Copilot CLI plugin that shows a Windows OS toast notification when a
turn takes longer than a threshold (default **30s**), so you can step away and
get pinged when Copilot finishes a long-running turn.

## How it works

The plugin registers two [hooks](https://docs.github.com/copilot) in
[`hooks/hooks.json`](hooks/hooks.json):

| Event | Phase | Action |
| --- | --- | --- |
| `userPromptSubmitted` | `Start` | Record the turn start time to a small state file. |
| `agentStop` | `Stop` | Compute elapsed time; if it exceeds the threshold, show a toast. |

[`hooks/Turn-Toast.ps1`](hooks/Turn-Toast.ps1) does the work. It is written to
**block the turn as little as possible**:

- The `Start` phase only writes one tiny file.
- The `Stop` phase reads/deletes that file and, when over threshold, launches the
  toast in a **detached** `pwsh` process and returns immediately — importing
  `BurntToast` and rendering a toast (~1s) never adds to turn latency.
- Failures are swallowed and nothing is written to stdout, so the hook can never
  disrupt or pollute a turn.

State files live in the per-plugin data directory Copilot exposes via
`COPILOT_PLUGIN_DATA` (falling back to `%TEMP%\turn-toast`), keyed by session id.

## Requirements

- Windows.
- The [BurntToast](https://github.com/Windos/BurntToast) PowerShell module
  (`Install-Module BurntToast`). This profile already installs it.
- PowerShell 7 (`pwsh`) on `PATH` (falls back to `powershell.exe`).

## Configuration

Set the threshold (in seconds) with an environment variable before launching
Copilot CLI:

```powershell
$env:TURN_TOAST_THRESHOLD_SEC = 60   # toast only on turns longer than 1 minute
```

If unset, the threshold is `30` seconds.

## Install

This plugin is published through the local `pwshprofile` marketplace defined in
`.github/plugin/marketplace.json`. Enable it from Copilot CLI with `/plugin`, or
add it to `enabledPlugins` in `~/.copilot/settings.json`:

```json
"enabledPlugins": {
  "turn-toast@pwshprofile": true
}
```
