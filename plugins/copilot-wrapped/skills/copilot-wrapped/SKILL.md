---
name: copilot-wrapped
description: "Generate a 'Copilot Wrapped': a fun, Spotify-Wrapped-style recap of your own Copilot CLI usage, built locally from the on-disk session store. Produces a self-contained HTML report with a day-of-week x time-of-day heatmap, top projects, task themes, files touched, streaks, and a personalized 'how to use Copilot better' section. Use when asked for 'copilot wrapped', 'my copilot usage recap', 'copilot year in review', 'copilot stats', 'how do I use copilot', or 'summarize my copilot history'."
---

# Copilot Wrapped

Turn your local Copilot CLI history into a fun, shareable recap — the way
Spotify Wrapped turns a year of listening into a story. The report celebrates
how you work *and* points out a few concrete ways to get more out of Copilot.

Everything is computed **on your machine** from the local session store. No
data is uploaded, and the database is opened **read-only**.

## When to use

Activate when the user asks for a "Copilot Wrapped", a usage recap / year in
review, "my Copilot stats", or wants to understand and improve how they use
Copilot.

## Data source

The skill reads the Copilot CLI session store, a SQLite database that defaults
to:

- `~/.copilot/session-store.db`

The skill reads two local sources:

- **`~/.copilot/session-store.db`** — a SQLite database with `sessions` (cwd,
  repository, summary, timestamps, `host_type`), `turns` (per-message user text,
  assistant reply, timestamp), `session_files`, and `checkpoints`.
- **`~/.copilot/session-state/*/events.jsonl`** — per-session event logs, scanned
  (read-only, streamed) for tool, skill, MCP-server, and model usage.

The script degrades gracefully if a table, the events directory, or a field is
absent. Use `--db <path>` / `--session-dir <path>` to point elsewhere, or
`--no-events` to skip the events scan.

> This is the **local** store only — it reflects sessions on this machine. It
> does not pull cloud history.

## Workflow

1. **Generate the report.** Run the bundled script. By default it writes a
   self-contained HTML file you can open in any browser:

   ```bash
   python3 scripts/wrapped_stats.py --output copilot-wrapped.html
   ```

   On Windows use `py -3 scripts\wrapped_stats.py --output copilot-wrapped.html`.
   The script prints a one-line summary (sessions / turns / files / projects).

2. **Inspect the numbers (optional, for a richer narrative).** To layer your
   own personalized commentary on top of the deterministic stats, get the raw
   JSON instead and read it:

   ```bash
   python3 scripts/wrapped_stats.py --json
   ```

   Use the JSON to write a short, friendly paragraph for the user (highlights,
   a surprising stat, one improvement to focus on). The quantitative charts in
   the HTML are authoritative — never invent numbers; only narrate what the
   JSON contains.

3. **Share the result.** Tell the user where the HTML landed and call out 2–3
   highlights plus the single most useful improvement from the "How to get even
   more out of Copilot" section.

## What it reports

- **Personality archetype**: a fun headline title (e.g. *The Code Reviewer*,
  *The Builder*) derived from your dominant task theme.
- **Totals**: sessions, turns, files touched, projects, longest day-streak.
- **Activity heatmap**: a 7×24 (day-of-week × hour, local time) grid showing
  when you actually work with Copilot, plus your peak day/hour and busiest day.
- **Top projects**: ranked by turns, derived from each session's `repository`
  (falling back to the working-directory name).
- **Task themes**: buckets like *Fixing bugs*, *Building features*,
  *Refactoring*, *Reviewing code*, inferred from session summaries, plus your
  most-used keywords.
- **Files & tools**: distinct files touched, top file extensions, and which
  edit tools you lean on.
- **Where you ran**: a Local PC / GitHub Codespace / ADO Cloud Agent breakdown
  (from `host_type` — specific machine names are not recorded locally).
- **Your toolkit** (from `events.jsonl`): most-used tools, **skills** you
  summoned, **MCP servers** you tapped, and **models** that did the work.
- **Copilot's voice**: top exclamations ("Done!", "Perfect!"), most-used emoji,
  and its favorite catchphrase.
- **How polite are you?**: your politeness percentage (please/thanks) plus
  Copilot's verbatim apologies, sorted by length.
- **Your style**: the you-vs-Copilot talk ratio, your longest single prompt, and
  average reply length.
- **Session shape**: average turns per session, your longest session, and how
  many were one-shot.
- **How to do better**: heuristic flags for suboptimal patterns — frequent
  mid-task course-corrections, marathon (15+ turn) sessions, terse one-word
  replies, and a high share of one-shot sessions — each with an actionable tip.

## Options

| Flag | Default | Meaning |
|------|---------|---------|
| `--output, -o` | `copilot-wrapped.html` | Output HTML path. |
| `--json` | off | Print the stats JSON to stdout instead of rendering HTML. |
| `--db` | `~/.copilot/session-store.db` | Path to the session store. |
| `--session-dir` | `~/.copilot/session-state` | Directory of per-session `events.jsonl` logs. |
| `--no-events` | off | Skip the events scan (tools / skills / MCP / models). |
| `--template` | bundled | Override the HTML template. |

## Notes & limitations

- Timestamps are converted to your **local** timezone for the day/hour charts.
- The store reflects only sessions recorded on this machine; older history may
  have been pruned. Tool/skill/MCP/model stats cover only sessions that still
  have an `events.jsonl` log.
- **Machine names are not recorded** — "Where you ran" reports the environment
  kind (local/Codespace/ADO), not a specific PC.
- Theme, archetype, voice, and improvement detection are heuristic — treat them
  as a fun, directional read, not a precise audit.

## Security Boundaries

This skill follows the [Security Principles](references/security-principles.md).

**This skill:**
- **CAN**: Open the local Copilot session store and per-session `events.jsonl`
  logs **read-only** and aggregate them; read the session summaries/turns/events
  the user already owns to compute stats and a narrative; copy the bundled HTML
  template and substitute the `/*__WRAPPED_DATA__*/null` data placeholder; write
  the resulting HTML report to the workspace.
- **CANNOT**: Modify, delete, or write to the session store, the event logs, or
  any session data; upload, transmit, or send any session content off the
  machine; add third-party/CDN dependencies to the output (it must stay
  self-contained and offline); fabricate statistics, projects, or timestamps not
  present in the data; read or expose secrets — only the user's own recorded
  prompts/summaries/usage are summarized, and the raw report stays local.
- **MUST CONFIRM**: Before overwriting an existing output file; before reading a
  session store at a non-default path supplied by someone other than the user;
  before sharing or copying the generated report anywhere outside the local
  workspace (it can contain prompt text and file paths).
