---
name: long-run
description: "Run a long-running command (build, test suite, sync) inside a detached zellij terminal session and open a live viewer window (a new tab in Windows Terminal when already inside it, otherwise a new window). The job is decoupled from the Copilot session, so it survives interrupts; the agent tracks completion and exit code through plain status/log files. Use when asked to 'run this in the background', 'kick off a long build', 'run it in zellij', 'watch the build in a terminal', 'run tests in a separate window', or 'don't let it die if the session is interrupted'."
---

# Long Run

Run a long command (a Chromium build, a gtest sweep, `gclient sync`, …) **inside
a detached [zellij](https://zellij.dev) session** with a live viewer terminal the
user can watch. Because zellij has a client/server split, the job is decoupled
from the Copilot CLI session: if the agent's turn is interrupted, the tool call
times out, or the viewer window is closed, **the job keeps running**. The agent
learns when it finished — and with what exit code — by reading two plain files,
never by blocking on the command.

## When to use

Use when the user wants a long command (more than ~30s) run in a real terminal
they can watch and that won't die with the agent turn — e.g. "run this build in
the background", "kick off the tests in a new window", "run it in zellij", or
"don't let it die if you get interrupted". Good fits: `autoninja` builds, gtest
sweeps, `gclient sync`, long lints. For quick commands, just use the shell tool.

## Requirements

- **zellij** on `PATH` (auto-detected at `%LOCALAPPDATA%\Zellij\zellij.exe`; the
  start script attempts a `winget` install if missing). A real terminal is
  required to host the session, so the viewer can't be fully hidden.
- **Windows Terminal** (`wt.exe`) for the viewer; falls back to a `pwsh` window.
- **PowerShell 7** (`pwsh`) for the scripts and the in-pane wrapper.

## How it works

```
agent shell (no TTY)              viewer window (real TTY)
Start-LongRun.ps1   ─ launches ▶  wt → zellij -s <sess> -n run.kdl
  └─ writes command/wrapper/         └─ pane runs wrapper.ps1:
     layout + Start-Process wt          status.txt: RUNNING <pid> → DONE <code>
     (returns instantly)                tees output → log.txt
Wait-LongRun.ps1  ─ polls status.txt/log.txt (never calls zellij) ─┘
```

State lives under `%TEMP%\long-run\<session>\`:
- `status.txt` — `PENDING` → `RUNNING <pid> <iso>` → `DONE <exitcode> <iso>`
- `log.txt` — full captured output (live)
- `command.ps1`, `wrapper.ps1`, `run.kdl` — generated job files

### The one hard rule

**Never run an *attaching* zellij command from the agent's shell** (`zellij
attach`, `zellij -s NAME -n …`, `zellij run …`) — the agent's shell has no TTY,
so these block forever. All session hosting happens in the viewer window via the
provided scripts. From the agent's shell, only ever run the scripts or
**non-attaching** queries: `zellij list-sessions -n`, `zellij kill-session`,
`zellij delete-session <name> --force`. The source of truth for "is it done / did
it pass" is **`status.txt`**, not zellij.

## Usage

Scripts are in `scripts/` next to this file.

**1. Start the job** — prints a machine-readable block (`LONGRUN_SESSION`,
`LONGRUN_DIR`, `LONGRUN_STATUS`, `LONGRUN_LOG`) the agent parses:

```powershell
pwsh -NoProfile -File <skill>/scripts/Start-LongRun.ps1 `
  -Command 'cmd.exe /c "<your full command>"' -WorkingDirectory 'Q:\cr\src'
```

`-Command` is passed verbatim (a `cmd.exe /c "...&& autoninja ..."` works
unchanged); the reported exit code is that command's. Optional: `-Session <name>`
for a stable re-attachable name (default is a slug from the command + timestamp);
`-NoViewer` tucks the viewer into a quake (`_quake`) window.

**2. Wait for completion** — run as a normal **sync** shell call with a generous
`initial_wait`:

```powershell
pwsh -NoProfile -File <skill>/scripts/Wait-LongRun.ps1 `
  -Session <name> -TimeoutSeconds 1800 -TailLines 40
```

Polls `status.txt`; on completion prints the log tail and `EXITCODE <n>` and
**exits with that code**. On timeout it prints a notice and exits `124` while the
job keeps running — just call it again to resume. Touches only files, so it's
safe in the agent's shell and interrupting it never affects the job.

**3. Peek / re-open / clean up:**

```powershell
Get-Content <LONGRUN_STATUS>             # PENDING / RUNNING / DONE <code>
Get-Content <LONGRUN_LOG> -Tail 40       # latest output
zellij kill-session <session>            # stop a still-running job
zellij delete-session <session> --force  # forget a finished one
```

To re-open a viewer, run `zellij attach <session>` **in a real terminal the user
controls** (or have the user do it) — never from the agent's shell.

## Suggested agent workflow

1. `Start-LongRun.ps1`; capture `LONGRUN_SESSION` / `…STATUS` / `…LOG`.
2. Tell the user the viewer opened and the job is decoupled.
3. `Wait-LongRun.ps1 -Session <s> -TimeoutSeconds <budget>` as a sync call.
4. On `EXITCODE 0` proceed; on non-zero, read `log.txt` to diagnose; on `124`
   wait again or report it's still running.
5. Clean up the session when done.

## Caveats

- **zellij on Windows is young** (ConPTY quirks). If a viewer fails to render,
  re-open with `zellij attach <session>`; the job is unaffected (it runs on the
  server).
- **Exit code = the command's last native process.** When wrapping several
  commands, make the one whose status matters the final native call.
- **Confirm before** killing/deleting a session the user may be watching, or
  before launching a destructive or expensive command.

## Security Boundaries

**This skill:**
- **CAN**: generate per-job helper files under `%TEMP%\long-run\<session>\`;
  start a zellij session via a Windows Terminal (or `pwsh`) viewer with
  `Start-Process` (non-blocking); run the user-provided command in that session;
  read the resulting `status.txt` / `log.txt`; run non-attaching zellij queries
  (`list-sessions`, `kill-session`, `delete-session`).
- **CANNOT**: run attaching zellij client commands from the agent's shell (they
  block without a TTY); host the session inside the agent's own shell; fabricate
  exit codes or completion — these come only from the job's `status.txt`.
- **MUST CONFIRM**: before killing or deleting a session the user may still be
  watching, and before launching a destructive or expensive command.
