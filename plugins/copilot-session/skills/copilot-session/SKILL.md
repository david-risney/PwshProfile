---
name: copilot-session
description: "Find, create, or fork GitHub Copilot CLI sessions by reading the on-disk session store (%USERPROFILE%\\.copilot\\session-state). Search existing sessions by working-directory path, repository (owner/name or git URL), branch, or name; start a new session; or fork an existing session into a new independent one (there is no official 'copilot fork' command, so this clones the session folder and rewrites its ids). Use when asked to 'find my Copilot sessions', 'search sessions by path/repo/branch', 'which session was for this folder', 'resume a session for repo X', 'fork this session', 'branch off a session', or 'start a new named session'."
---

# Copilot Session

Find, create, or **fork** GitHub Copilot CLI sessions directly from the on-disk
session store — no running CLI required.

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
# All sessions, newest first
pwsh -NoProfile -File <skill>/scripts/Copilot-Session.ps1 -Action Find

# By path (substring of cwd/git_root; '.' = current dir)
... -Action Find -Path .
... -Action Find -Path 'source\repos\my-repo'

# By repository (slug substring, or paste a git URL)
... -Action Find -Repository owner/repo
... -Action Find -Repository https://github.com/owner/repo.git

# By branch and/or name; only running sessions; JSON for scripting
... -Action Find -Branch my-feature -Name "design" -LiveOnly -Json
```

Prints a table (`Id`, `Name`, `Branch`, `Repository`, `Updated`, `KB`, `Live`,
`Cwd`). `Live` `*` marks a session that currently holds a lock. Resume any with
`copilot --resume=<id>`.

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

## Interactive use (from the shell)

The repository's `profile.ps1` dot-sources `helper-copilot.ps1`, which exposes
this **same script** as shell functions (single source of truth) so you can use
it directly from your prompt:

```powershell
Copilot-Session -Action Find -Path .        # or the presets below
Find-CopilotSession -Repository owner/repo   # cops <-- alias for Find
New-CopilotSession  -NewName "my feature" -Launch
Fork-CopilotSession -Session a8579b9 -NewName experiment -Launch
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
  forking a running session (has a `*` in `Live`) may capture a partial
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
