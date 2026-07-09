---
name: long-run
description: "Run one or more long-running commands (build, test suite, sync) inside a detached terminal-multiplexer session (psmux, or zellij as a fallback) and open a live viewer: a new tab in the current psmux/zellij session if already inside one, else a new tab in the current Windows Terminal window, else a new pwsh window. Multiple commands each run in their own pane. The job is decoupled from the Copilot session, so it survives interrupts; the agent tracks completion and exit code through plain status/log files. Prefer this for ANY long build (autoninja/siso/ninja), gclient sync, or large test sweep — even when another skill (e.g. the build skill) would otherwise run the command directly, route it through long-run so it survives interrupts and its exit code/log are tracked. Use when asked to 'run this in the background', 'kick off a long build', 'run these in parallel panes', 'run it in psmux', 'run it in zellij', 'watch the build in a terminal', 'run tests in a separate window', or 'don't let it die if the session is interrupted'."
---

# Long Run

Run a long command (a Chromium build, a gtest sweep, `gclient sync`, …) **inside
a detached terminal-multiplexer session**. Pass several commands to run them
**side by side, each in its own pane**. The tool prefers
[psmux](https://github.com/psmux/psmux) (a tmux alternative for Windows) and
falls back to [zellij](https://zellij.dev). Because the multiplexer has a
client/server split, the job is decoupled from the Copilot CLI session: if the
agent's turn is interrupted, the tool call times out, or the viewer window is
closed, **the job keeps running**. The agent learns when it finished — and with
what exit code — by reading two plain files, never by blocking on the command.

## When to use

(Skill selection is driven by the frontmatter `description`; this is just a
sanity check once the skill is loaded.) Good fits: commands expected to run more
than ~30s — `autoninja` builds, gtest sweeps, `gclient sync`, long lints. Don't
use it for quick commands — run those directly with the shell tool.

## Requirements

- A terminal multiplexer. The start script chooses one automatically:
  - **Prefer psmux** (`psmux`/`pmux` on `PATH`, or
    `%LOCALAPPDATA%\Microsoft\WinGet\Links\psmux.exe`).
  - Use **zellij** only if zellij is installed and psmux is not
    (auto-detected at `%LOCALAPPDATA%\Zellij\zellij.exe`).
  - If **neither** is installed, it installs psmux via
    `winget install --id marlocarlo.psmux`.
  - **Exception:** if the script is already running *inside* a psmux or zellij
    session, that multiplexer is used so the job opens as a new tab there.
- **Windows Terminal** (`wt.exe`) for the viewer when not already inside a
  session; falls back to a `pwsh` window.
- **PowerShell 7** (`pwsh`) for the scripts and the in-pane wrapper.

## How it works

```
agent shell (no TTY)              viewer (real TTY)
Start-LongRun.ps1   ─ launches ▶  psmux/zellij tab or window
  └─ writes command/wrapper/         └─ pane runs wrapper.ps1:
     layout, starts a detached          status.txt: RUNNING <pid> → DONE <code>
     mux session or new tab             tees output → log.txt
     (returns instantly)
Wait-LongRun.ps1  ─ polls status.txt/log.txt (never calls the mux) ─┘
```

**Viewer selection:**
- Already inside a **psmux/zellij** session → open a **new tab in that session**.
- Else inside **Windows Terminal** → open a **new tab in the current WT window**.
- Else → open a **new pwsh window**.

With psmux, a not-yet-inside job is hosted by a **detached session** that starts
immediately and headlessly (so `-NoViewer` is fully background); a viewer just
attaches to it. With zellij, the session is hosted by the viewer (zellij needs a
real TTY), so `-NoViewer` uses a hidden console.

State lives under `%TEMP%\long-run\<session>\`:
- `status.txt` — `PENDING` → `RUNNING <pid> <iso>` → `DONE <exitcode> <iso>`
- `log.txt` — full captured output (live)
- `command.ps1`, `wrapper.ps1`, and (zellij only) `run.kdl` — generated job files

With **multiple commands** each pane gets its own indexed set —
`status.<i>.txt`, `log.<i>.txt`, `command.<i>.ps1`, `wrapper.<i>.ps1` (1-based) —
and the single `run.kdl` (zellij) declares one pane per command.

> **Why a wrapper instead of just asking the multiplexer?** Both psmux
> (`psmux capture-pane -p -t <session>`) and zellij (`zellij --session <s>
> action dump-screen --full --path <file>`) can dump a pane non-attaching, but
> that only yields a point-in-time snapshot bounded by the scrollback buffer (a
> long build overflows it), it disappears when the session ends, and neither has
> an exit-code mechanism. So the wrapper tees a complete, persistent `log.txt`
> and records the exit code in `status.txt`. Use a pane capture as a complement
> to grab exactly what's on screen (e.g. output a child process printed straight
> to the console).

### The one hard rule

**Never run an *attaching* multiplexer client command from the agent's shell**
(`psmux`/`psmux attach`, `zellij attach`, `zellij -s NAME -n …`) — the agent's
shell has no TTY, so these block forever. All session *hosting* happens in the
viewer window via the provided scripts. From the agent's shell, only ever run
the scripts or **non-attaching** commands:
- psmux: `psmux ls`, `psmux new-session -d …`, `psmux new-window -d …`,
  `psmux kill-session -t <name>`, `psmux capture-pane -p -t <name>`.
- zellij: `zellij list-sessions -n`, `zellij kill-session`,
  `zellij delete-session <name> --force`,
  `zellij --session <s> action dump-screen …`.

The source of truth for "is it done / did it pass" is **`status.txt`**, not the
multiplexer.

## Usage

Scripts are in `scripts/` next to this file.

**1. Start the job** — prints a machine-readable block (`LONGRUN_MUX`,
`LONGRUN_SESSION`, `LONGRUN_DIR`, `LONGRUN_COUNT`, and per-command
`LONGRUN_STATUS[_i]` / `LONGRUN_LOG[_i]`) the agent parses:

```powershell
pwsh -NoProfile -File <skill>/scripts/Start-LongRun.ps1 `
  -Command 'cmd.exe /c "<your full command>"' -WorkingDirectory 'Q:\cr\src'
```

Run **several commands, each in its own pane**, by passing them as additional
positional arguments (put named parameters *before* the commands):

```powershell
pwsh -NoProfile -File <skill>/scripts/Start-LongRun.ps1 -WorkingDirectory 'Q:\cr\src' `
  'cmd.exe /c "<build command>"' 'cmd.exe /c "<test command>"'
```

Each command is passed verbatim (a `cmd.exe /c "...&& autoninja ..."` works
unchanged); the reported exit code for a pane is that command's. When a single
command is given the legacy `LONGRUN_STATUS`/`LONGRUN_LOG` (and `status.txt` /
`log.txt`) are used; with multiple commands the files are indexed per pane.
Optional: `-Session <name>` for a stable re-attachable name (default is a slug
from the first command + timestamp); `-NoViewer` runs without opening a viewer
(fully headless with psmux; a hidden console with zellij).

**2. Wait for completion** — run as a normal **sync** shell call with a generous
`initial_wait`:

```powershell
pwsh -NoProfile -File <skill>/scripts/Wait-LongRun.ps1 `
  -Session <name> -TimeoutSeconds 1800 -TailLines 40
```

Polls the status file(s); on completion prints each pane's log tail and
`EXITCODE <n>` and **exits with the overall code** (0 only if every pane exited
0, else the first non-zero pane code). For a multi-command job, pass `-Index <i>`
to wait for just one pane. On timeout it prints a notice and exits `124` while
the job keeps running — just call it again to resume. Touches only files, so
it's safe in the agent's shell and interrupting it never affects the job.

**3. Peek / re-open / clean up** (use the multiplexer reported in `LONGRUN_MUX`):

```powershell
Get-Content <LONGRUN_STATUS>                 # PENDING / RUNNING / DONE <code>
Get-Content <LONGRUN_LOG> -Tail 40           # latest output

# psmux
psmux capture-pane -p -t <session>           # exact on-screen snapshot
psmux kill-session -t <session>              # stop a still-running job

# zellij
zellij --session <session> action dump-screen --full --path <file>
zellij kill-session <session>                # stop a still-running job
zellij delete-session <session> --force      # forget a finished one
```

To re-open a viewer, run the `Re-open a viewer any time with: …` command printed
by `Start-LongRun.ps1` (`psmux attach -t <session>` or `zellij attach
<session>`) **in a real terminal the user controls** — never from the agent's
shell.

## Suggested agent workflow

1. `Start-LongRun.ps1`; capture `LONGRUN_MUX` / `LONGRUN_SESSION` / `…STATUS` /
   `…LOG`.
2. Tell the user the viewer opened and the job is decoupled.
3. `Wait-LongRun.ps1 -Session <s> -TimeoutSeconds <budget>` as a sync call.
4. On `EXITCODE 0` proceed; on non-zero, read `log.txt` to diagnose; on `124`
   wait again or report it's still running.
5. Clean up the session when done.

## Caveats

- **Multiplexers on Windows have console quirks.** If a viewer fails to render,
  re-open it with the printed attach command; the job is unaffected (it runs on
  the server).
- **Exit code = the command's last native process.** When wrapping several
  commands, make the one whose status matters the final native call.
- **Confirm before** killing/deleting a session the user may be watching, or
  before launching a destructive or expensive command.

## Security Boundaries

**This skill:**
- **CAN**: generate per-job helper files under `%TEMP%\long-run\<session>\`;
  start a detached psmux/zellij session (or a new tab in the current session)
  via a Windows Terminal tab or `pwsh` window with `Start-Process`
  (non-blocking); install psmux via winget when no multiplexer is present; run
  the user-provided command in that session; read the resulting `status.txt` /
  `log.txt`; run non-attaching multiplexer queries (`psmux ls`/`capture-pane`,
  `zellij list-sessions`, `kill-session`, `delete-session`).
- **CANNOT**: run attaching multiplexer client commands from the agent's shell
  (they block without a TTY); host the session inside the agent's own shell;
  fabricate exit codes or completion — these come only from the job's
  `status.txt`.
- **MUST CONFIRM**: before killing or deleting a session the user may still be
  watching, and before launching a destructive or expensive command.
