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
  `BurntToast` and rendering a toast (~1s) never adds to turn latency. The detached
  process holds open briefly after issuing the toast, because on PowerShell 7 the
  notification is delivered asynchronously and Windows silently drops the banner if
  the process exits too quickly.
- Failures are swallowed and nothing is written to stdout, so the hook can never
  disrupt or pollute a turn.

State files live in the per-plugin data directory Copilot exposes via
`COPILOT_PLUGIN_DATA` (falling back to `%TEMP%\turn-toast`), keyed by session id
when the hook payload provides one. In current Copilot CLI versions the
`userPromptSubmitted`/`agentStop` payloads do **not** include `session_id`, so
the state file is keyed as `turn-default.txt` — harmless, since both phases use
the same key and timing still pairs correctly.

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

## Diagnostics / logging

Copilot does not surface hook execution, so the plugin writes its own diagnostic
log. At every decision point (`Start` wrote the state file; `Stop` computed
elapsed vs. threshold; toast launched / skipped / errored) **and at every failure
point** it appends a line to:

```
<COPILOT_PLUGIN_DATA>\turn-toast.log      # falls back to %TEMP%\turn-toast\turn-toast.log
```

For this plugin that is typically:

```
%USERPROFILE%\.copilot\plugin-data\pwshprofile\turn-toast\turn-toast.log
```

Tail it while you exercise a long turn to see whether both hooks fire and why a
toast did or did not appear:

```powershell
Get-Content "$env:USERPROFILE\.copilot\plugin-data\pwshprofile\turn-toast\turn-toast.log" -Wait -Tail 20
```

Each line looks like:

```
2026-07-18 21:21:15.939 -07:00  [Start pid:1234 INFO]   Start: wrote state file '...turn-default.txt' startMs=1784434875939
2026-07-18 21:21:47.512 -07:00  [Stop pid:5678 INFO]    Stop: elapsedSec=31.6 thresholdSec=30
2026-07-18 21:21:47.520 -07:00  [Stop pid:5678 INFO]    Stop: launched detached toast via '...pwsh.exe' elapsedText='31.6s' (done)
2026-07-18 21:21:48.402 -07:00  [Toast pid:9012]        toast issued (elapsed 31.6s); holding process open so Windows can present it
2026-07-18 21:21:56.410 -07:00  [Toast pid:9012]        toast process exiting after hold (elapsed 31.6s)
```

Each line is tagged with a level (`INFO`/`WARN`/`ERROR`). Every failure is logged
rather than silently swallowed, so problems are visible — for example a missing
`BurntToast` module surfaces from the **detached toast process** itself:

```
2026-07-18 21:21:48.402 -07:00  [Toast pid:9012]        toast FAILED: The specified module 'BurntToast' was not loaded...
```

Logging is **on by default**. Disable it by setting the environment variable
`TURN_TOAST_LOG` to `0` (or `false`/`off`) before launching Copilot CLI. Logging
never writes to stdout and never throws, so it can't disrupt a turn.

## Install

This plugin is published through the local `pwshprofile` marketplace defined in
`.github/plugin/marketplace.json`. Enable it from Copilot CLI with `/plugin`, or
add it to `enabledPlugins` in `~/.copilot/settings.json`:

```json
"enabledPlugins": {
  "turn-toast@pwshprofile": true
}
```
