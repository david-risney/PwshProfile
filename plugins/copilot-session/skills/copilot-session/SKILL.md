---
name: copilot-session
description: "Find, create, fork, or sync GitHub Copilot CLI sessions by reading the on-disk session store (%USERPROFILE%\\.copilot\\session-state). Search existing sessions by working-directory path, repository (owner/name or git URL), branch, or name; start a new session; fork an existing session into a new independent one (there is no official 'copilot fork' command, so this clones the session folder and rewrites its ids); or sync/pull a cloud session or task down for local use via copilot --resume/--connect. Find also surfaces cloud/agent sessions synced to disk. Use when asked to 'find my Copilot sessions', 'search sessions by path/repo/branch', 'which session was for this folder', 'resume a session for repo X', 'fork this session', 'branch off a session', 'start a new named session', 'pull down a cloud session', or 'sync a cloud/remote session locally'."
---

# Copilot Session

Find, create, **fork**, or **sync** GitHub Copilot CLI sessions directly from the
on-disk session store — no running CLI required.

## Where sessions live

Every Copilot CLI session is a folder under
`%USERPROFILE%\.copilot\session-state\<id>\`. The searchable index is each
folder's `workspace.yaml`:

```yaml
id: a8579b92-0e23-4677-8578-11a6048096c0
cwd: C:\Users\you\source\repos\my-repo
git_root: C:\Users\you\source\repos\my-repo
repository: owner/Project/repo        # slug, not a URL
branch: user/you/my-feature
name: my session
created_at: 2026-06-04T18:12:49.788Z
updated_at: 2026-07-07T21:23:44.932Z
mc_task_id / mc_session_id / mc_last_event_id   # remote-attach ids (forks drop these)
```

Other files in the folder: `events.jsonl` (the full transcript; the session id
is embedded throughout), `session.db` (SQLite), `checkpoints/`, `files/`,
`*.lock` (present while the session is running).

## Is there an official way to fork? No.

The CLI has **no `fork` command**. Its session flags only *resume or attach to*
an existing id:

- `copilot --resume[=<id|prefix|name>]` — resume a previous session (7+ char id
  prefix or exact, case-insensitive name; no value → interactive picker).
- `copilot --continue` — resume the most recent session.
- `copilot --session-id=<id>` — resume an existing id, or set the UUID for a new
  session.
- `copilot --connect[=<id>]` — attach to a remote session/task.

Resuming keeps writing to the **same** history. To branch off a session's
history into an independent copy you must duplicate the folder and rewrite its
identifiers — that's what `-Action Fork` does: new `id`, `mc_*` remote ids
stripped (so it doesn't reattach to the seed and warn "session already
running"), the seed id replaced throughout `events.jsonl`, and `inbox_entries`
in `session.db` repointed (best-effort).

## Usage

The script is `scripts/Copilot-Session.ps1` next to this file.

### Find

```powershell
# Default view: non-empty sessions for the current repo/folder, most turns first
pwsh -NoProfile -File <skill>/scripts/Copilot-Session.ps1 -Action Find

# By path (substring of cwd/git_root; '.' = current dir)
... -Action Find -Path .
... -Action Find -Path 'source\repos\my-repo'

# By repository (slug substring, or paste a git URL)
... -Action Find -Repository owner/repo
... -Action Find -Repository https://github.com/owner/repo.git

# By branch and/or name; only running sessions; JSON for scripting
... -Action Find -Branch my-feature -Name "design" -LiveOnly -Json

# List everything (bypass default relevance filters), or cap the default view
... -Action Find -All
... -Action Find -Top 50

# Reorder: most turns (default), most recently updated, or longest-lived
... -Action Find -Sort Recent
... -Action Find -Sort Duration

# Jump straight into the top-ranked match instead of listing it
... -Action Find -Resume                              # open it in a right split pane (default)
... -Action Find -Resume -ResumeDirection Left        # open it in a left split pane
... -Action Find -Resume -ResumeDirection InPlace     # run it in the current terminal
... -Action Find -Sort Recent -Resume                 # resume the most recently updated
... -Action Find -Name "systray" -Resume              # resume the top "systray" match
```

By default Find shows only non-empty sessions (>=1 user turn) for the current
repo/folder, ordered by **most turns first** (duration then recency as tiebreaks)
and capped at the `-Top` most (default 30) -- this surfaces your most-used
sessions. Pass `-Sort Recent` (most recently updated) or `-Sort Duration`
(longest-lived) to reorder, `-All` to bypass the relevance filters, or `-Top N`
to change the cap.

Prints a table (`Id` (full session id), `Src` (`local` or `cloud`), `Branch`,
`Turns` (# of your prompts), `Dur` (session lifespan), `PID`, `Folder` (cwd),
`Name`). The `PID` column shows the process id of the **currently running**
process that holds the session's lock (blank when idle); the pid is verified, so
stale locks from crashed/closed sessions no longer appear. Resume any with
`copilot --resume=<id>`.

Use `-Resume` to skip the listing and jump straight into the top-ranked match
with `copilot --resume=<id>`. `-ResumeDirection` chooses **where copilot opens**:

- `Right` (default) / `Left` -- open a split pane on that side, in the session's
  own folder, using whichever pane manager you're in: **psmux** (`$env:TMUX`),
  **zellij** (`$env:ZELLIJ`), or **Windows Terminal** (`$env:WT_SESSION`). With
  none of those available it falls back to running in place. `Right` is the
  default because every supported pane manager can place a pane on the right;
  `Left` is honored exactly only by psmux (`-b`), while zellij's `new-pane`
  supports only right/down and WT opens the new pane adjacent to the focused one,
  so on those two `Left` is a normal side-by-side split. The pane logic is the
  shared `Open-CommandPane` helper (`shared\Terminal-Panes.ps1`, vendored into
  both this skill and long-run), which picks the `wt.exe` for the Windows
  Terminal **edition** actually hosting you (stable vs Preview) so the split
  lands in the current window, and takes psmux's fast profile path so copilot
  starts promptly instead of waiting on the full interactive pwsh profile.
- `InPlace` -- run `copilot --resume=<id>` in the current terminal.

## Performance

Find derives its columns from each session's `workspace.yaml` (metadata) and
`events.jsonl` (turn counts) -- with hundreds of sessions on disk (some with
very large event logs), re-reading them every run is slow. Results are cached in
`~/.copilot/session-state/.find-cache.json`, keyed by each file's size+mtime, so
unchanged sessions are never re-read: a warm run is typically well under a
second. The very first run (or after many sessions change) still pays a one-time
read. The live/PID lock check is likewise resolved only for the handful of
sessions actually shown (or for every session only when `-LiveOnly` is used). The
cache lives outside the repo, self-prunes deleted sessions, and safely rebuilds
if missing or corrupt.

Combine `-Resume` with filters and `-Sort` to control which session is picked. If
the picked session is **already running** (has a `PID`), copilot can't open a
second live instance of it, so `-Resume` instead **switches focus to that
session's existing terminal window** (walking up the process tree to find the
hosting pwsh/WindowsTerminal window). If the window can't be located (e.g. a
detached psmux pane), it tells you to switch manually or `Fork` a copy. Idle or
stale-locked sessions resume normally.

Find also surfaces **cloud/agent sessions** that were synced to disk but have no
`workspace.yaml` (started or steered from GitHub web/mobile); these show `Src` =
`cloud` and have thinner metadata (usually no name/branch; cwd is recovered from
their events). Pass `-LocalOnly` to hide them.

### New

```powershell
pwsh -NoProfile -File <skill>/scripts/Copilot-Session.ps1 -Action New `
  -NewName "my feature" -WorkingDirectory 'C:\src\my-repo'
```

Prints `SESSION_CMD=copilot --name "my feature" -C C:\src\my-repo`. Add
`-Launch` to open it in a new terminal (a tab in the current Windows Terminal
window, else a new pwsh window) instead of only printing the command.

### Fork

```powershell
# Fork a specific session (id, 7+ char prefix, or exact name)
pwsh -NoProfile -File <skill>/scripts/Copilot-Session.ps1 -Action Fork -Session a8579b9

# Or select by filters (must resolve to exactly one session)
... -Action Fork -Path . -Branch my-feature -NewName "experiment"

# Fork and immediately open it in a new terminal
... -Action Fork -Session a8579b9 -Launch
```

Creates a new independent session and prints `SESSION_ID`, `SESSION_DIR`, and
`SESSION_CMD=copilot --resume=<newid>`. Optional overrides: `-NewName`,
`-Branch`, `-WorkingDirectory` (rewrites the fork's cwd/git_root). Selection by
filters is refused unless it matches exactly one session (the error lists the
candidates).

### Sync (pull a cloud session down)

```powershell
# Resume a cloud session/task by id (materializes it locally when opened)
pwsh -NoProfile -File <skill>/scripts/Copilot-Session.ps1 -Action Sync -Session <cloud-id-or-task-id>

# Attach to the live remote session instead of resuming a copy
... -Action Sync -Session <id> -Connect

# Pull it down and open it immediately in a new terminal
... -Action Sync -Session <id> -Launch
```

Prints `SESSION_ID` and `SESSION_CMD=copilot --resume=<id>` (or `--connect=<id>`
with `-Connect`). There is no "download only" command -- resuming/attaching by id
is what brings a cloud session onto this machine. Discovering cloud-only ids is
out of scope for this local script (the CLI has no "list cloud sessions"
command); get them from GitHub web/mobile or another synced machine.

## Interactive use (from the shell)

The repository's `profile.ps1` dot-sources `helper-copilot.ps1`, which exposes
this **same script** as shell functions (single source of truth) so you can use
it directly from your prompt:

```powershell
Copilot-Session -Action Find -Path .        # or the presets below
Find-CopilotSession -Repository owner/repo   # cops <-- alias for Find
New-CopilotSession  -NewName "my feature" -Launch
Fork-CopilotSession -Session a8579b9 -NewName experiment -Launch
Sync-CopilotSession -Session <cloud-id-or-task-id> -Launch
```

All arguments are forwarded verbatim to `scripts/Copilot-Session.ps1`.

## Suggested agent workflow

1. `Find` with the tightest filter you have (`-Path .` inside a repo is common).
2. If the user wants to continue an existing session, give them
   `copilot --resume=<id>`.
3. If they want to branch off, `Fork` the chosen session, then hand back the
   printed `copilot --resume=<newid>` (or run with `-Launch`).

## Caveats

- **Don't fork a live session mid-write.** The copy is a point-in-time snapshot;
  forking a running session (one that shows a `PID`) may capture a partial
  `events.jsonl`. Prefer forking idle sessions; confirm with the user first.
- **`session.db` inbox repoint is best-effort** (needs `python`); the transcript
  fork works regardless.
- **Forks accumulate.** Each fork is a full copy of the seed folder (can be many
  MB). Delete unwanted forks by removing their `session-state\<id>` folder.
- Reading the store is safe and read-only; only `Fork` writes (a brand-new
  folder) and only `-Launch` starts a process.

## Security Boundaries

**This skill:**
- **CAN**: read `workspace.yaml` / file sizes across `session-state` to list and
  search sessions; copy a session folder to a new id and rewrite its
  `workspace.yaml` / `events.jsonl` / `session.db` to create an independent
  fork; print (or, with `-Launch`, start via `Start-Process`) a `copilot`
  command in a new terminal.
- **CANNOT**: modify or resume the original (seed) session; fabricate session
  contents; delete existing sessions.
- **SHOULD CONFIRM**: before forking a **live** session, and before launching
  interactive sessions on the user's behalf.
