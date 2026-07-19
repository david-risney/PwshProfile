# turn-toast

A GitHub Copilot CLI plugin that shows a Windows OS toast notification when a
turn takes longer than a threshold (default **60s**), so you can step away and
get pinged when Copilot finishes a long-running turn.

## How it works

The plugin registers two [hooks](https://docs.github.com/copilot) in
[`hooks/hooks.json`](hooks/hooks.json):

| Event | Phase | Action |
| --- | --- | --- |
| `userPromptSubmitted` | `Start` | Record the turn start time to a small state file. |
| `agentStop` | `Stop` | Compute elapsed time; if it exceeds the threshold, the terminal isn't the foreground window, **and Copilot is actually ready for your input** (see below), show a toast (labelled with the session/repo/path) with a **Focus terminal** button. |

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

## Only notifies when you've looked away

If the terminal that ran the turn is still the foreground window when the turn
finishes, **no toast is shown** — the goal is to ping you only when you've
switched to another window while a long turn ran. The check compares the
foreground window against the terminal's handle and runs inside the detached
process at notify time, so it adds nothing to turn latency. If the terminal
window can't be resolved, the toast is shown anyway (fail-open).

## Only notifies when Copilot is ready for your input

A toast should mean "Copilot is done and waiting for you" — never a ping in the
middle of a long autonomous run. The `Stop` phase reads the session's event
transcript (`transcriptPath`) to decide:

- **Interactive mode** — every over-threshold turn is a real hand-back to you, so
  it can toast.
- **Autopilot mode** — Copilot keeps working across many turns, so intermediate
  stops are **suppressed** (it will auto-continue). The toast fires only when the
  task actually completes (`task_complete`), and the elapsed time is measured
  from the **start of the autopilot run** — not the last auto-injected "keep
  going" reminder — so a long autonomous task still crosses the threshold and
  pings you exactly once when it's finished.

Mode and completion are detected from the last ~250 transcript lines (cheaply
substring-filtered before JSON parsing). If the transcript can't be read, it
falls back to plain per-turn timing (fail-open).

## Toast content

The toast body includes a short label identifying which session the turn
belonged to, chosen in this order:

1. The session's **user-provided name** (when you've named the session —
   `user_named: true` in the session's `workspace.yaml`).
2. Otherwise the **git repo** name (the `repository` slug's name, or the
   `git_root` folder), when the session is in a repo.
3. Otherwise the **working directory** path.

The label is read from the session's `workspace.yaml` (no `git` invocation) and
clamped to 40 characters — keeping the tail of long paths and the head of long
names, with an ellipsis.

## Clicking the notification

The toast includes a **Focus terminal** button that brings the terminal window
that started the turn back to the foreground.

- During the `Stop` phase the hook walks up its own parent-process tree (it runs
  inside the Copilot CLI / terminal process tree) to the first ancestor that
  owns a real window — the terminal window. This is deterministic and works even
  after you switch away to another app.
- That window handle is embedded in the button as a custom `turntoast:<hwnd>`
  URL. The detached toast process registers the `turntoast:` protocol under
  `HKCU:\Software\Classes` pointing at
  [`hooks/Focus-Window.ps1`](hooks/Focus-Window.ps1).
- When you click the button, Windows launches `Focus-Window.ps1`, which parses
  the handle and forces that window to the foreground (restoring it if
  minimized), using the `AttachThreadInput` trick so activation succeeds
  reliably.

> BurntToast 1.1.0 does not expose whole-toast-body protocol activation, so the
> reactivation is wired to a button rather than the notification body.

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

If unset, the threshold is `60` seconds.

## Install

This plugin is published through the local `pwshprofile` marketplace defined in
`.github/plugin/marketplace.json`. Enable it from Copilot CLI with `/plugin`, or
add it to `enabledPlugins` in `~/.copilot/settings.json`:

```json
"enabledPlugins": {
  "turn-toast@pwshprofile": true
}
```
