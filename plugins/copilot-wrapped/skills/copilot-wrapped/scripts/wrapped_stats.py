#!/usr/bin/env python3
"""Copilot Wrapped -- build a fun usage recap from the local Copilot session store.

Reads the on-disk Copilot CLI session database (read-only) and emits either a
JSON stats blob (--json) or a self-contained HTML report (default). Standard
library only; the database is never modified and nothing is sent off-machine.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import glob
import html
import json
import os
import re
import sqlite3
import sys

DEFAULT_DB = os.path.join(os.path.expanduser("~"), ".copilot", "session-store.db")
DEFAULT_SESSION_DIR = os.path.join(os.path.expanduser("~"), ".copilot", "session-state")
TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "assets", "wrapped-template.html")
PLACEHOLDER = "/*__WRAPPED_DATA__*/null"

DOW = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

# Lightweight task-theme buckets keyed by verbs/nouns found in session summaries.
THEME_RULES = [
    ("Fixing bugs", r"\b(fix|bug|crash|regress|repair|broke|broken|defect)\w*"),
    ("Building features", r"\b(add|implement|build|create|feature|introduce|new)\w*"),
    ("Refactoring", r"\b(refactor|cleanup|clean up|rename|restructure|simplify|tidy)\w*"),
    ("Reviewing code", r"\b(review|pr feedback|comment|approve|audit)\w*"),
    ("Testing", r"\b(test|coverage|unit test|spec|pytest|assert)\w*"),
    ("Debugging", r"\b(debug|investigat|root cause|trace|diagnos|why)\w*"),
    ("Docs & writing", r"\b(doc|readme|comment|write up|markdown|explain)\w*"),
    ("Build & CI", r"\b(build|compile|ci|pipeline|lint|gn |ninja)\w*"),
    ("Git & PRs", r"\b(commit|branch|merge|rebase|pull request|\bpr\b|push)\w*"),
]

# Phrases in a user turn that suggest the previous response missed the mark.
FRICTION_PATTERNS = [
    r"\bthat'?s (wrong|not right|incorrect)\b",
    r"\bnot what i\b",
    r"\b(un)?do that\b",
    r"\brevert\b",
    r"\byou broke\b",
    r"\bstill (failing|broken|not working|doesn'?t work)\b",
    r"\bdoesn'?t work\b",
    r"\bdidn'?t work\b",
    r"\btry again\b",
    r"\bthat didn'?t\b",
    r"\bno,? (that|this|stop|don'?t)\b",
    r"\bstop\b",
    r"\bwrong\b",
]
FRICTION_RE = re.compile("|".join(FRICTION_PATTERNS), re.IGNORECASE)

STOPWORDS = set("""a an the and or but for to of in on at by with from into this that
these those is are was were be been being it its as you your i we they he she them
their our my me do does did done can could should would will just so if then than
about over under via use using used make made get got run ran new now here there
what when where which who why how please thanks thank ok okay yes no not need want
me up out off again still also into onto per vs etc edge copilot session""".split())

# Celebratory words Copilot tends to open with -- counted only when punched
# with a "!" so it reads as a genuine exclamation.
EXCLAIM_WORDS = ["Done", "Great", "Perfect", "Excellent", "Awesome", "Nice",
                 "Got it", "Yes", "Indeed", "Absolutely", "Wonderful", "Boom",
                 "Sweet", "Bingo"]
EMOJI_RE = re.compile("[\U0001F000-\U0001FAFF\u2600-\u27BF\u2B00-\u2BFF\u2190-\u21FF\u2300-\u23FF]")
APOLOGY_RE = re.compile(r"you('?re| are) (absolutely |totally |quite |completely )?(right|correct)"
                        r"|\bapolog|\bsorry\b|good catch|nice catch"
                        r"|my (mistake|bad|error)"
                        r"|i was (wrong|mistaken|incorrect)"
                        r"|i (misunderstood|misread|overlooked)|i missed that"
                        r"|\boops\b|(fair|good) point"
                        r"|you('?ve| have) (a|got a) point", re.IGNORECASE)
POLITE_RE = re.compile(r"\b(please|thanks|thank you|appreciate|kindly)\b", re.IGNORECASE)
CATCHPHRASE_RE = re.compile(r"\b(let me|let's|i'?ll|here'?s|now i'?ll|sure|got it|on it)\b",
                            re.IGNORECASE)

# Map the dominant task theme to a fun "Copilot personality" archetype.
ARCHETYPES = {
    "Reviewing code": ("The Code Reviewer", "You live in other people's diffs."),
    "Testing": ("The Test Pilot", "Red, green, refactor -- repeat."),
    "Building features": ("The Builder", "Always shipping the next thing."),
    "Debugging": ("The Detective", "No stack trace survives you."),
    "Refactoring": ("The Renovator", "Leaving every file cleaner than you found it."),
    "Fixing bugs": ("The Bug Slayer", "Squashing defects one repro at a time."),
    "Docs & writing": ("The Scribe", "If it isn't written down, did it happen?"),
    "Git & PRs": ("The Merge Master", "Branch, rebase, ship, repeat."),
    "Build & CI": ("The Pipeline Wrangler", "Keeping the green checks green."),
}

# host_type in the store maps to where the session physically ran.
HOST_LABELS = {None: "Local PC", "": "Local PC", "local": "Local PC",
               "github": "GitHub Codespace", "ado": "ADO Cloud Agent"}


def _parse(ts: str | None) -> dt.datetime | None:
    if not ts:
        return None
    try:
        d = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.astimezone()  # convert to local time for "your" activity


def _project_label(repository: str | None, cwd: str | None) -> str:
    if repository:
        return repository
    if cwd:
        return re.split(r"[\\/]", cwd.rstrip("\\/"))[-1] or cwd
    return "unknown"


def connect(db_path: str) -> sqlite3.Connection:
    if not os.path.exists(db_path):
        sys.exit(
            f"error: session store not found at {db_path}\n"
            "This skill reads your local Copilot CLI history. Pass --db <path> "
            "if your store lives elsewhere."
        )
    uri = "file:" + db_path.replace("\\", "/") + "?mode=ro&immutable=1"
    return sqlite3.connect(uri, uri=True)


def _has_table(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "select 1 from sqlite_master where type='table' and name=?", (name,)
    ).fetchone()
    return row is not None


def build_stats(conn: sqlite3.Connection) -> dict:
    sessions = list(conn.execute(
        "select id, repository, cwd, summary, created_at, updated_at, host_type "
        "from sessions"))
    turns = list(conn.execute(
        "select session_id, turn_index, user_message, timestamp, assistant_response "
        "from turns"))

    # --- totals -------------------------------------------------------------
    session_dates = [_parse(s[4]) for s in sessions]
    session_dates = [d for d in session_dates if d]
    turn_times = [_parse(t[3]) for t in turns]
    turn_times = [d for d in turn_times if d]

    first = min(session_dates) if session_dates else None
    last = max(session_dates) if session_dates else None
    active_days = {d.date() for d in turn_times} | {d.date() for d in session_dates}

    # --- heatmap (dow x hour) ----------------------------------------------
    heatmap = [[0] * 24 for _ in range(7)]
    by_dow = collections.Counter()
    by_hour = collections.Counter()
    by_date = collections.Counter()
    for d in turn_times:
        heatmap[d.weekday()][d.hour] += 1
        by_dow[DOW[d.weekday()]] += 1
        by_hour[d.hour] += 1
        by_date[d.date().isoformat()] += 1

    busiest_hour = max(by_hour, key=by_hour.get) if by_hour else None
    busiest_dow = max(by_dow, key=by_dow.get) if by_dow else None
    busiest_date = max(by_date, key=by_date.get) if by_date else None

    # --- projects -----------------------------------------------------------
    proj_sessions = collections.Counter()
    sid_to_proj = {}
    where_ran = collections.Counter()
    for sid, repo, cwd, _summ, _ca, _ua, host in sessions:
        label = _project_label(repo, cwd)
        proj_sessions[label] += 1
        sid_to_proj[sid] = label
        where_ran[HOST_LABELS.get(host, str(host))] += 1
    proj_turns = collections.Counter()
    for sid, _idx, _msg, _ts, _resp in turns:
        proj_turns[sid_to_proj.get(sid, "unknown")] += 1
    top_projects = [
        {"name": name, "sessions": cnt, "turns": proj_turns.get(name, 0)}
        for name, cnt in proj_sessions.most_common(8)
    ]

    # --- task themes (from summaries) --------------------------------------
    summaries = " \n ".join((s[3] or "") for s in sessions).lower()
    themes = []
    for label, pat in THEME_RULES:
        hits = len(re.findall(pat, summaries, re.IGNORECASE))
        if hits:
            themes.append({"name": label, "count": hits})
    themes.sort(key=lambda x: x["count"], reverse=True)

    words = collections.Counter()
    for tok in re.findall(r"[a-zA-Z][a-zA-Z+#.-]{2,}", summaries):
        tok = tok.strip(".-").lower()
        if tok and tok not in STOPWORDS and len(tok) > 2:
            words[tok] += 1
    top_keywords = [{"word": w, "count": c} for w, c in words.most_common(20)]

    # --- files --------------------------------------------------------------
    file_count = 0
    ext_counter = collections.Counter()
    tool_counter = collections.Counter()
    if _has_table(conn, "session_files"):
        rows = list(conn.execute("select file_path, tool_name from session_files"))
        file_count = len({r[0] for r in rows if r[0]})
        for path, tool in rows:
            ext = (os.path.splitext(path or "")[1] or "(none)").lower()
            ext_counter[ext] += 1
            if tool:
                tool_counter[tool] += 1
    top_ext = [{"ext": e, "count": c} for e, c in ext_counter.most_common(10)]

    # --- streak (consecutive active days) ----------------------------------
    streak = _longest_streak(sorted(active_days))

    # --- per-session turn distribution -------------------------------------
    turns_per_session = collections.Counter()
    for sid, _idx, _msg, _ts, _resp in turns:
        turns_per_session[sid] += 1
    counts = sorted(turns_per_session.values())
    avg_turns = round(sum(counts) / len(counts), 1) if counts else 0
    longest_session = max(counts) if counts else 0
    single_turn = sum(1 for c in counts if c == 1)

    # --- voice & style (the fun stuff) -------------------------------------
    voice = _voice_and_style(turns)

    # --- personality archetype ---------------------------------------------
    archetype = None
    if themes:
        name, blurb = ARCHETYPES.get(themes[0]["name"],
                                     ("The Generalist", "A bit of everything."))
        archetype = {"title": name, "blurb": blurb, "from": themes[0]["name"]}

    # --- friction / improvement heuristics ---------------------------------
    insights = _improvement_insights(turns, turns_per_session, single_turn,
                                     len(sessions))

    return {
        "meta": {
            "generated_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
            "first_session": first.date().isoformat() if first else None,
            "last_session": last.date().isoformat() if last else None,
            "active_days": len(active_days),
            "tz": dt.datetime.now().astimezone().tzname(),
        },
        "totals": {
            "sessions": len(sessions),
            "turns": len(turns),
            "files": file_count,
            "projects": len(proj_sessions),
            "checkpoints": _count(conn, "checkpoints"),
        },
        "heatmap": heatmap,
        "by_dow": {d: by_dow.get(d, 0) for d in DOW},
        "by_hour": {str(h): by_hour.get(h, 0) for h in range(24)},
        "busiest": {
            "hour": busiest_hour,
            "dow": busiest_dow,
            "date": busiest_date,
            "date_turns": by_date.get(busiest_date, 0) if busiest_date else 0,
        },
        "top_projects": top_projects,
        "themes": themes,
        "top_keywords": top_keywords,
        "files": {"distinct": file_count, "by_ext": top_ext,
                  "by_tool": [{"tool": t, "count": c}
                              for t, c in tool_counter.most_common(6)]},
        "streak_days": streak,
        "session_shape": {
            "avg_turns": avg_turns,
            "longest_session_turns": longest_session,
            "single_turn_sessions": single_turn,
        },
        "where_you_ran": [{"name": k, "count": v}
                          for k, v in where_ran.most_common()],
        "archetype": archetype,
        "voice": voice,
        "insights": insights,
    }


def _count(conn: sqlite3.Connection, table: str) -> int:
    if not _has_table(conn, table):
        return 0
    return conn.execute(f'select count(*) from "{table}"').fetchone()[0]


def _longest_streak(days: list) -> int:
    if not days:
        return 0
    best = run = 1
    for i in range(1, len(days)):
        if (days[i] - days[i - 1]).days == 1:
            run += 1
            best = max(best, run)
        elif days[i] != days[i - 1]:
            run = 1
    return best


def _improvement_insights(turns, turns_per_session, single_turn, n_sessions):
    friction = 0
    terse = 0
    for _sid, _idx, msg, _ts, _resp in turns:
        m = (msg or "").strip()
        if FRICTION_RE.search(m):
            friction += 1
        if 0 < len(m) <= 4:  # "no", "stop", "yes"
            terse += 1
    long_sessions = sum(1 for c in turns_per_session.values() if c >= 15)

    out = []
    if friction:
        out.append({
            "title": "Course-corrections",
            "metric": friction,
            "tip": "You re-steered Copilot mid-task this many times. Front-load "
                   "constraints and acceptance criteria in your first prompt to "
                   "cut back-and-forth.",
        })
    if long_sessions:
        out.append({
            "title": "Marathon sessions (15+ turns)",
            "metric": long_sessions,
            "tip": "Very long sessions can mean going in circles. When stuck, "
                   "ask Copilot to summarize the plan and restart fresh with a "
                   "tighter scope.",
        })
    if terse:
        out.append({
            "title": "One-word replies",
            "metric": terse,
            "tip": "Short 'no'/'stop' replies waste a turn. Say what you want "
                   "instead (e.g. 'stop and revert the last edit') for faster "
                   "recovery.",
        })
    if n_sessions and single_turn / n_sessions > 0.5:
        out.append({
            "title": "Mostly one-shot sessions",
            "metric": f"{round(100 * single_turn / n_sessions)}%",
            "tip": "Over half your sessions were a single turn. Copilot shines "
                   "across follow-ups -- keep iterating in one session to reuse "
                   "its context instead of starting over.",
        })
    return out


def _apology_snippet(text):
    """Return the sentence containing an apology, condensed and length-capped."""
    for sent in re.split(r"(?<=[.!?])\s+", text):
        if APOLOGY_RE.search(sent):
            s = " ".join(sent.split())
            if len(s) > 280:
                mobj = APOLOGY_RE.search(s)
                start = max(0, mobj.start() - 110)
                s = ("\u2026" if start > 0 else "") + s[start:start + 250].strip() + "\u2026"
            return s
    return None


def _voice_and_style(turns):
    """Fun personality stats mined from message text (Copilot + you)."""
    exclaim = collections.Counter()
    emoji = collections.Counter()
    catchphrase = collections.Counter()
    apology_quotes = []
    emoji_turns = apologies = polite = 0
    user_lens = []
    asst_lens = []
    for _sid, _idx, umsg, _ts, aresp in turns:
        u = umsg or ""
        a = aresp or ""
        user_lens.append(len(u))
        asst_lens.append(len(a))
        if POLITE_RE.search(u):
            polite += 1
        if APOLOGY_RE.search(a):
            apologies += 1
            snip = _apology_snippet(a)
            if snip:
                apology_quotes.append(snip)
        ems = EMOJI_RE.findall(a)
        if ems:
            emoji_turns += 1
            for e in ems:
                emoji[e] += 1
        for w in EXCLAIM_WORDS:
            n = len(re.findall(r"\b" + re.escape(w) + r"\b!", a, re.IGNORECASE))
            if n:
                exclaim[w] += n
        for m in CATCHPHRASE_RE.findall(a):
            catchphrase[m.lower()] += 1

    avg_u = round(sum(user_lens) / len(user_lens)) if user_lens else 0
    avg_a = round(sum(asst_lens) / len(asst_lens)) if asst_lens else 0
    top_phrase = catchphrase.most_common(1)
    quotes = sorted(dict.fromkeys(apology_quotes), key=len, reverse=True)
    return {
        "exclamations": [{"word": w, "count": c} for w, c in exclaim.most_common(8)],
        "top_emoji": [{"emoji": e, "count": c} for e, c in emoji.most_common(8)],
        "emoji_turns": emoji_turns,
        "apologies": apologies,
        "apology_quotes": quotes[:12],
        "catchphrase": top_phrase[0][0] if top_phrase else None,
        "catchphrase_count": top_phrase[0][1] if top_phrase else 0,
        "polite_turns": polite,
        "polite_pct": round(100 * polite / len(user_lens)) if user_lens else 0,
        "total_turns": len(user_lens),
        "avg_user_chars": avg_u,
        "avg_assistant_chars": avg_a,
        "talk_ratio": round(avg_u / avg_a, 1) if avg_a else 0,
        "longest_prompt_chars": max(user_lens) if user_lens else 0,
    }


def scan_events(session_root):
    """Aggregate tool / skill / MCP / model usage from per-session events.jsonl.

    Streams each JSONL file and only parses lines for tool-start events, so it
    stays fast over large logs. Returns None if the directory is absent.
    """
    if not os.path.isdir(session_root):
        return None
    tools = collections.Counter()
    skills = collections.Counter()
    mcp_servers = collections.Counter()
    mcp_tools = collections.Counter()
    models = collections.Counter()
    sessions_scanned = 0
    for path in glob.glob(os.path.join(session_root, "*", "events.jsonl")):
        sessions_scanned += 1
        try:
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    if "tool.execution_start" not in line:
                        continue
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    if e.get("type") != "tool.execution_start":
                        continue
                    d = e.get("data") or {}
                    tn = d.get("toolName")
                    if tn:
                        tools[tn] += 1
                    mdl = d.get("model")
                    if mdl:
                        models[mdl] += 1
                    if tn == "skill":
                        s = (d.get("arguments") or {}).get("skill")
                        if s:
                            skills[s] += 1
                    srv = d.get("mcpServerName")
                    if srv:
                        mcp_servers[srv] += 1
                        mt = d.get("mcpToolName")
                        if mt:
                            mcp_tools[f"{srv}/{mt}"] += 1
        except OSError:
            continue
    return {
        "sessions_scanned": sessions_scanned,
        "top_tools": [{"tool": t, "count": c} for t, c in tools.most_common(12)],
        "skills_used": [{"name": s, "count": c} for s, c in skills.most_common(15)],
        "mcp_servers": [{"name": s, "count": c} for s, c in mcp_servers.most_common(10)],
        "mcp_tools": [{"name": s, "count": c} for s, c in mcp_tools.most_common(10)],
        "models": [{"name": m, "count": c} for m, c in models.most_common(8)],
        "total_tool_calls": sum(tools.values()),
    }


def render_html(stats: dict, template_path: str) -> str:
    with open(template_path, "r", encoding="utf-8") as fh:
        tpl = fh.read()
    if PLACEHOLDER not in tpl:
        sys.exit(f"error: template missing placeholder {PLACEHOLDER}")
    blob = json.dumps(stats, ensure_ascii=False)
    # Guard against breaking out of the <script> context.
    blob = blob.replace("</", "<\\/")
    return tpl.replace(PLACEHOLDER, blob)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build a Copilot Wrapped report.")
    ap.add_argument("--db", default=DEFAULT_DB, help="path to session-store.db")
    ap.add_argument("--template", default=TEMPLATE, help="HTML template path")
    ap.add_argument("--output", "-o", default="copilot-wrapped.html",
                    help="output HTML path (ignored with --json)")
    ap.add_argument("--json", action="store_true",
                    help="print the stats JSON instead of rendering HTML")
    ap.add_argument("--session-dir", default=DEFAULT_SESSION_DIR,
                    help="path to the session-state directory (events.jsonl logs)")
    ap.add_argument("--no-events", action="store_true",
                    help="skip the events.jsonl scan (tools/skills/MCP/models)")
    args = ap.parse_args(argv)

    conn = connect(args.db)
    try:
        stats = build_stats(conn)
    finally:
        conn.close()

    if not args.no_events:
        events = scan_events(args.session_dir)
        if events is not None:
            stats["usage"] = events

    if args.json:
        json.dump(stats, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    out_html = render_html(stats, args.template)
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(out_html)
    t = stats["totals"]
    sys.stderr.write(
        f"Wrote {args.output}  ({t['sessions']} sessions, {t['turns']} turns, "
        f"{t['files']} files across {t['projects']} projects)\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
