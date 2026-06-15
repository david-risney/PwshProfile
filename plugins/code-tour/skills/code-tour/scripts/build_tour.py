#!/usr/bin/env python3
"""Validate a code-tour JSON document and render it to HTML, Markdown, or CLI.

This script performs every deterministic, non-AI step of the code-tour skill:

  * load + validate the tour JSON (the only artifact the AI produces),
  * fill the shipped HTML template (copy template, substitute the
    ``__TOUR_JSON__`` placeholder, escaping any literal ``</script>``),
  * or render the same JSON to a Markdown document or ANSI CLI text,
  * write the result to disk (refusing to clobber unless ``--force``).

The AI's job is reduced to generating the JSON tour; this script does the rest.

Usage:
    python build_tour.py TOUR.json [--format html|md|cli]
                         [--output PATH] [--template PATH] [--force]

``TOUR.json`` may be ``-`` to read the JSON from stdin. With ``--format cli``
and no ``--output`` the rendering is written to stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import textwrap

# Resolve the shipped template relative to this script, so the skill works no
# matter what the current working directory is.
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_TEMPLATE = os.path.normpath(
    os.path.join(_SCRIPT_DIR, "..", "assets", "tour-template.html")
)
_PLACEHOLDER = "__TOUR_JSON__"

_REF_RE = re.compile(r"\[\[([^\]]+)\]\]")
_CODE_RE = re.compile(r"`([^`]+)`")
_BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


class TourError(Exception):
    """A fatal problem with the tour document or the requested operation."""


# Mermaid runtime files copied next to an HTML tour when it has diagrams.
_MERMAID_ASSETS = ("mermaid.esm.min.mjs", "mermaid.min.js")


def diagram_source(d):
    """Return the Mermaid source for a diagram entry (string or {code|mermaid})."""
    if isinstance(d, str):
        return d
    if isinstance(d, dict):
        return d.get("code") or d.get("mermaid") or ""
    return ""


def diagram_title(d):
    """Return the optional title for a diagram entry, or None."""
    if isinstance(d, dict):
        return d.get("title")
    return None


def tour_has_diagrams(tour):
    """True if the intro or any section carries at least one diagram."""
    if tour.get("diagrams"):
        return True
    for section in tour.get("sections") or []:
        if isinstance(section, dict) and section.get("diagrams"):
            return True
    return False


def group_name(group):
    """A group's display name accepts either 'title' or the 'name' alias."""
    if not isinstance(group, dict):
        return ""
    return group.get("title") or group.get("name") or ""


def ordered_sections(tour):
    """Return sections in rendered order, honoring optional ``groups``.

    Yields dicts ``{section, number, group, group_start}``. Grouped sections
    come first (in group then listed order); ungrouped sections follow in their
    original order. ``group_start`` marks the first section of each group.
    """
    sections = tour.get("sections") or []
    by_id = {}
    for i, s in enumerate(sections):
        if isinstance(s, dict):
            by_id[s.get("id") or ("section-%d" % i)] = s
    ordered = []
    used = set()
    for group in tour.get("groups") or []:
        if not isinstance(group, dict):
            continue
        for sid in group.get("sections") or []:
            s = by_id.get(sid)
            if s is not None and sid not in used:
                used.add(sid)
                ordered.append({"section": s, "group": group})
    for i, s in enumerate(sections):
        sid = s.get("id") or ("section-%d" % i) if isinstance(s, dict) else None
        if sid is not None and sid not in used:
            used.add(sid)
            ordered.append({"section": s, "group": None})
    prev_group = None
    for idx, entry in enumerate(ordered):
        s = entry["section"]
        entry["number"] = s.get("number", idx + 1) if isinstance(s, dict) else idx + 1
        entry["group_start"] = bool(entry["group"]) and entry["group"] is not prev_group
        prev_group = entry["group"]
    return ordered


# --------------------------------------------------------------------------- #
# Loading + validation
# --------------------------------------------------------------------------- #

def load_tour(source: str) -> dict:
    """Read and parse the tour JSON from a path (or ``-`` for stdin)."""
    if source == "-":
        raw = sys.stdin.read()
    else:
        if not os.path.isfile(source):
            raise TourError("tour JSON not found: %s" % source)
        with open(source, "r", encoding="utf-8") as handle:
            raw = handle.read()
    try:
        tour = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise TourError("tour JSON does not parse: %s" % exc)
    if not isinstance(tour, dict):
        raise TourError("tour JSON must be a JSON object at the top level")
    return tour


def _file_line_count(path: str):
    """Return the number of lines in ``path`` on disk, or ``None`` if unreadable."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return None


def _iter_refs(text):
    """Yield ``(file_or_None, start, end_or_None)`` for every ``[[...]]`` token."""
    if not text:
        return
    for match in _REF_RE.finditer(str(text)):
        body = match.group(1)
        ref_file = None
        rng = body
        if ":" in body:
            ref_file, rng = body.split(":", 1)
        parts = rng.split("-")
        try:
            start = int(parts[0])
        except ValueError:
            continue
        end = None
        if len(parts) > 1 and parts[1]:
            try:
                end = int(parts[1])
            except ValueError:
                end = None
        yield ref_file, start, end


def _check_diagrams(where, diagrams, errors):
    """Validate a ``diagrams`` array (string or {title?, code|mermaid} entries)."""
    if diagrams is None:
        return
    if not isinstance(diagrams, list):
        errors.append("%s diagrams must be an array" % where)
        return
    for i, d in enumerate(diagrams):
        if isinstance(d, str):
            if not d.strip():
                errors.append("%s diagram[%d] is empty" % (where, i))
        elif isinstance(d, dict):
            src = d.get("code") or d.get("mermaid")
            if not src or not str(src).strip():
                errors.append(
                    "%s diagram[%d] has no non-empty 'code'/'mermaid' source"
                    % (where, i))
        else:
            errors.append(
                "%s diagram[%d] must be a string or a {title?, code} object"
                % (where, i))


def validate_tour(tour: dict) -> list:
    """Validate the tour. Returns a list of non-fatal warnings; raises on errors."""
    errors = []
    warnings = []

    if not tour.get("title"):
        errors.append("missing required top-level field: title")

    files = tour.get("files")
    if not isinstance(files, dict) or not files:
        errors.append("missing or empty required top-level field: files (object)")
        files = {}

    sections = tour.get("sections")
    if not isinstance(sections, list) or not sections:
        errors.append("missing or empty required top-level field: sections (array)")
        sections = []

    _check_diagrams("intro", tour.get("diagrams"), errors)

    # Cache real line counts for files that exist on disk.
    line_counts = {}
    for name, path in files.items():
        if isinstance(path, str):
            line_counts[name] = _file_line_count(path)

    def check_range(where, fname, start, end):
        if fname is not None and fname not in files:
            errors.append("%s references file %r not declared in files" % (where, fname))
            return
        target = fname
        if end is not None and start is not None and end < start:
            errors.append("%s has lineEnd (%s) < lineStart (%s)" % (where, end, start))
        total = line_counts.get(target) if target is not None else None
        if total is not None:
            hi = end if end is not None else start
            if start is not None and (start < 1 or hi > total):
                errors.append(
                    "%s line range %s-%s is outside %s (1-%d)"
                    % (where, start, hi, target, total)
                )

    seen_ids = set()
    for idx, section in enumerate(sections):
        where = "section[%d]" % idx
        if not isinstance(section, dict):
            errors.append("%s is not an object" % where)
            continue
        sid = section.get("id")
        if not sid:
            errors.append("%s missing required field: id" % where)
        elif sid in seen_ids:
            errors.append("%s has duplicate id %r" % (where, sid))
        else:
            seen_ids.add(sid)
            where = "section %r" % sid

        _check_diagrams(where, section.get("diagrams"), errors)

        sfile = section.get("file")
        if sfile is not None and sfile not in files:
            errors.append("%s references file %r not declared in files" % (where, sfile))

        start = section.get("lineStart")
        end = section.get("lineEnd")
        if start is not None:
            if sfile is None:
                errors.append("%s has lineStart but no file" % where)
            else:
                check_range(where, sfile, start, end)
        elif end is not None:
            errors.append("%s has lineEnd without lineStart" % where)

        if "code" in section and not isinstance(section.get("code"), str):
            errors.append(
                "%s field 'code' must be a string (got %s) - a renderer shows "
                "it verbatim, so an object/array becomes '[object Object]'"
                % (where, type(section.get("code")).__name__))

        for an_idx, anchor in enumerate(section.get("anchors") or []):
            awhere = "%s anchor[%d]" % (where, an_idx)
            afile = anchor.get("file") or sfile
            astart = anchor.get("lineStart")
            if astart is None:
                errors.append("%s missing required field: lineStart" % awhere)
            else:
                check_range(awhere, afile, astart, anchor.get("lineEnd"))

        # Inline [[...]] references in body/title and callouts.
        for field in ("title", "body"):
            for ref_file, rstart, rend in _iter_refs(section.get(field)):
                check_range("%s %s reference" % (where, field),
                            ref_file or sfile, rstart, rend)
        for c_idx, callout in enumerate(section.get("callouts") or []):
            for ref_file, rstart, rend in _iter_refs(callout.get("text")):
                check_range("%s callout[%d] reference" % (where, c_idx),
                            ref_file or sfile, rstart, rend)

    # Optional groups: a top-level table of contents over the flat sections.
    groups = tour.get("groups")
    if groups is not None:
        if not isinstance(groups, list):
            errors.append("groups must be an array")
            groups = []
        seen_group_ids = set()
        placed = {}
        for gidx, group in enumerate(groups):
            gwhere = "group[%d]" % gidx
            if not isinstance(group, dict):
                errors.append("%s is not an object" % gwhere)
                continue
            gid = group.get("id")
            if gid is not None:
                if gid in seen_group_ids:
                    errors.append("%s has duplicate id %r" % (gwhere, gid))
                else:
                    seen_group_ids.add(gid)
                gwhere = "group %r" % gid
            if not (group.get("title") or group.get("name")):
                errors.append("%s missing required field: title (or name)" % gwhere)
            gsections = group.get("sections")
            if not isinstance(gsections, list) or not gsections:
                errors.append("%s missing or empty required field: sections (array)" % gwhere)
                gsections = []
            for sid in gsections:
                if sid not in seen_ids:
                    errors.append("%s references unknown section id %r" % (gwhere, sid))
                elif sid in placed:
                    errors.append(
                        "%s section %r already grouped under %r"
                        % (gwhere, sid, placed[sid]))
                else:
                    placed[sid] = gwhere

    if errors:
        # De-duplicate while preserving first-seen order.
        seen = set()
        unique = []
        for err in errors:
            if err not in seen:
                seen.add(err)
                unique.append(err)
        raise TourError(
            "tour validation failed:\n  - " + "\n  - ".join(unique)
        )
    return warnings


# --------------------------------------------------------------------------- #
# HTML rendering (fill the shipped template)
# --------------------------------------------------------------------------- #

def render_html(tour: dict, template_path: str) -> str:
    if not os.path.isfile(template_path):
        raise TourError("HTML template not found: %s" % template_path)
    with open(template_path, "r", encoding="utf-8") as handle:
        template = handle.read()
    count = template.count(_PLACEHOLDER)
    if count != 1:
        raise TourError(
            "template must contain the %s placeholder exactly once (found %d): %s"
            % (_PLACEHOLDER, count, template_path)
        )
    # Re-serialize so the embedded text is guaranteed valid and escape any
    # literal "</script>" as "<\/script>" (a valid JSON escape for "/") so it
    # cannot terminate the surrounding <script> element.
    payload = json.dumps(tour, ensure_ascii=False, indent=2)
    payload = payload.replace("</script>", "<\\/script>")
    return template.replace(_PLACEHOLDER, payload)


# --------------------------------------------------------------------------- #
# Shared link helpers (Markdown + CLI)
# --------------------------------------------------------------------------- #

def _abs_path(tour, file):
    files = tour.get("files") or {}
    return files.get(file, file)


def _line_href(tour, file, start):
    if tour.get("webUrlBase"):
        return "%s%s#L%s" % (tour["webUrlBase"], file, start)
    scheme = ("vscode-insiders://file/" if tour.get("editor") == "vscode-insiders"
              else "vscode://file/")
    return "%s%s:%s" % (scheme, _abs_path(tour, file), start)


def _ref_label(file, start, end, web):
    if end and end != start:
        span = "%s\u2013%s" % (start, end)
    else:
        span = str(start)
    if web:
        return "%s#L%s" % (file, start)
    return "%s:%s" % (file, span)


# --------------------------------------------------------------------------- #
# Markdown rendering
# --------------------------------------------------------------------------- #

def _md_inline(tour, file, text):
    if text is None:
        return ""
    web = bool(tour.get("webUrlBase"))

    def ref_sub(match):
        body = match.group(1)
        ref_file = file
        rng = body
        if ":" in body:
            ref_file, rng = body.split(":", 1)
        parts = rng.split("-")
        try:
            start = int(parts[0])
        except ValueError:
            return match.group(0)
        end = int(parts[1]) if len(parts) > 1 and parts[1] else None
        label = _ref_label(ref_file, start, end, web)
        return "[`%s`](%s)" % (label, _line_href(tour, ref_file, start))

    out = _REF_RE.sub(ref_sub, str(text))
    return out


def _md_block(tour, file, text, out):
    if not text:
        return
    for block in re.split(r"\n\s*\n", str(text)):
        lines = block.split("\n")
        is_list = (all(re.match(r"^\s*-\s+", l) or not l.strip() for l in lines)
                   and any(re.match(r"^\s*-\s+", l) for l in lines))
        if is_list:
            for line in lines:
                m = re.match(r"^\s*-\s+(.*)$", line)
                if m:
                    out.append("- " + _md_inline(tour, file, m.group(1)))
            out.append("")
        else:
            out.append(_md_inline(tour, file, block.replace("\n", " ")))
            out.append("")


_CALLOUT_LABEL = {"good": "\u2705 ", "warn": "\u26a0\ufe0f ",
                  "danger": "\u26d4 ", "info": "\u2139\ufe0f "}


def _md_diagrams(diagrams, out):
    for d in diagrams or []:
        src = diagram_source(d)
        if not str(src).strip():
            continue
        title = diagram_title(d)
        if title:
            out.append("**%s**" % title)
            out.append("")
        out.append("```mermaid")
        out.append(str(src).rstrip("\n"))
        out.append("```")
        out.append("")


def render_markdown(tour: dict) -> str:
    out = []
    out.append("# " + str(tour.get("title", "Code tour")))
    if tour.get("subtitle"):
        out.append("")
        out.append("*" + str(tour["subtitle"]) + "*")
    out.append("")

    _md_block(tour, None, tour.get("intro"), out)
    _md_diagrams(tour.get("diagrams"), out)

    notes = tour.get("designNotes") or []
    if notes:
        out.append("> **Design notes**")
        out.append(">")
        for note in notes:
            out.append("> - " + _md_inline(tour, None, note))
        out.append("")

    sections = tour.get("sections") or []
    groups = tour.get("groups") or []
    ordered = ordered_sections(tour)
    by_id = {}
    for i, s in enumerate(sections):
        if isinstance(s, dict):
            by_id[s.get("id") or ("section-%d" % i)] = s
    number_by_id = {}
    for entry in ordered:
        s = entry["section"]
        number_by_id[s.get("id")] = entry["number"]

    if ordered:
        out.append("## Contents")
        out.append("")
        if groups:
            for gi, group in enumerate(groups):
                out.append("### %s" % group_name(group))
                if group.get("description"):
                    out.append("")
                    out.append(_md_inline(tour, None, group.get("description")))
                out.append("")
                for sid in group.get("sections") or []:
                    s = by_id.get(sid)
                    if not s:
                        continue
                    out.append("%s. [%s](#%s)" % (number_by_id.get(sid, ""),
                                                  s.get("title", ""), sid))
                out.append("")
            orphans = [e for e in ordered if not e["group"]]
            if orphans:
                out.append("### Other")
                out.append("")
                for e in orphans:
                    s = e["section"]
                    out.append("%s. [%s](#%s)" % (e["number"], s.get("title", ""),
                                                  s.get("id", "")))
                out.append("")
        else:
            for entry in ordered:
                s = entry["section"]
                out.append("%s. [%s](#%s)" % (entry["number"], s.get("title", ""),
                                              s.get("id", "")))
            out.append("")

    for entry in ordered:
        s = entry["section"]
        num = entry["number"]
        if entry["group_start"]:
            group = entry["group"]
            out.append("## %s" % group_name(group))
            if group.get("description"):
                out.append("")
                out.append(_md_inline(tour, None, group.get("description")))
            out.append("")
        heading = "## %s. %s" % (num, _md_inline(tour, s.get("file"), s.get("title", "")))
        out.append(heading)
        meta = []
        if s.get("file") and s.get("lineStart"):
            web = bool(tour.get("webUrlBase"))
            label = _ref_label(s["file"], s["lineStart"], s.get("lineEnd"), web)
            meta.append("[`%s`](%s)" % (label, _line_href(tour, s["file"], s["lineStart"])))
        elif s.get("file"):
            meta.append("`%s`" % s["file"])
        if meta:
            out.append("")
            out.append(" ".join(meta))
        out.append("")
        _md_block(tour, s.get("file"), s.get("body"), out)
        if s.get("code"):
            out.append("```")
            out.append(s["code"])
            out.append("```")
            out.append("")
        for callout in s.get("callouts") or []:
            label = _CALLOUT_LABEL.get(callout.get("type", "info"), "")
            body = _md_inline(tour, s.get("file"), callout.get("text", ""))
            out.append("> %s%s" % (label, body))
            out.append("")
        _md_diagrams(s.get("diagrams"), out)
        anchors = s.get("anchors") or []
        if anchors:
            jumps = []
            web = bool(tour.get("webUrlBase"))
            for an in anchors:
                af = an.get("file") or s.get("file")
                lab = an.get("label") or _ref_label(af, an["lineStart"],
                                                     an.get("lineEnd"), web)
                jumps.append("[`%s`](%s)" % (lab, _line_href(tour, af, an["lineStart"])))
            out.append("Jump to: " + " \u00b7 ".join(jumps))
            out.append("")

    if tour.get("dataFlow"):
        out.append("## Putting it together \u2014 the data flow")
        out.append("")
        _md_block(tour, None, tour.get("dataFlow"), out)

    return "\n".join(out).rstrip() + "\n"


# --------------------------------------------------------------------------- #
# CLI (ANSI) rendering
# --------------------------------------------------------------------------- #

_ANSI = {
    "reset": "\033[0m", "bold": "\033[1m", "dim": "\033[2m",
    "title": "\033[1;36m", "head": "\033[1;33m", "code": "\033[36m",
    "good": "\033[32m", "warn": "\033[33m", "danger": "\033[31m",
    "info": "\033[34m", "link": "\033[4;34m",
}


def _ansi_inline(tour, file, text, color=True):
    if text is None:
        return ""
    web = bool(tour.get("webUrlBase"))

    def ref_sub(match):
        body = match.group(1)
        ref_file = file
        rng = body
        if ":" in body:
            ref_file, rng = body.split(":", 1)
        parts = rng.split("-")
        try:
            start = int(parts[0])
        except ValueError:
            return match.group(0)
        end = int(parts[1]) if len(parts) > 1 and parts[1] else None
        label = _ref_label(ref_file, start, end, web)
        return ("%s%s%s" % (_ANSI["link"], label, _ANSI["reset"])) if color else label

    out = _REF_RE.sub(ref_sub, str(text))
    out = _LINK_RE.sub(lambda m: m.group(1), out)
    if color:
        out = _CODE_RE.sub(lambda m: _ANSI["code"] + m.group(1) + _ANSI["reset"], out)
        out = _BOLD_RE.sub(lambda m: _ANSI["bold"] + m.group(1) + _ANSI["reset"], out)
    else:
        out = _CODE_RE.sub(lambda m: m.group(1), out)
        out = _BOLD_RE.sub(lambda m: m.group(1), out)
    return out


def _ansi_block(tour, file, text, out, color):
    if not text:
        return
    for block in re.split(r"\n\s*\n", str(text)):
        lines = block.split("\n")
        is_list = (all(re.match(r"^\s*-\s+", l) or not l.strip() for l in lines)
                   and any(re.match(r"^\s*-\s+", l) for l in lines))
        if is_list:
            for line in lines:
                m = re.match(r"^\s*-\s+(.*)$", line)
                if m:
                    wrapped = textwrap.fill(_ansi_inline(tour, file, m.group(1), color),
                                            width=88, initial_indent="  \u2022 ",
                                            subsequent_indent="    ")
                    out.append(wrapped)
        else:
            wrapped = textwrap.fill(_ansi_inline(tour, file, block.replace("\n", " "), color),
                                    width=88)
            out.append(wrapped)
        out.append("")


def render_cli(tour: dict, color=True) -> str:
    def c(key):
        return _ANSI[key] if color else ""

    def diagrams(entries):
        for d in entries or []:
            src = diagram_source(d)
            if not str(src).strip():
                continue
            title = diagram_title(d)
            label = "diagram (mermaid)" + ((": " + title) if title else "")
            out.append(c("dim") + "  \u250c\u2500 " + label + c("reset"))
            for line in str(src).rstrip("\n").split("\n"):
                out.append(c("dim") + "  \u2502 " + c("reset") + line)
            out.append(c("dim") + "  \u2514\u2500" + c("reset"))
            out.append("")

    out = []
    out.append(c("title") + str(tour.get("title", "Code tour")) + c("reset"))
    if tour.get("subtitle"):
        out.append(c("dim") + str(tour["subtitle"]) + c("reset"))
    out.append("")

    _ansi_block(tour, None, tour.get("intro"), out, color)
    diagrams(tour.get("diagrams"))

    for note in tour.get("designNotes") or []:
        out.append(c("good") + "  \u25c6 " + c("reset") + _ansi_inline(tour, None, note, color))
    if tour.get("designNotes"):
        out.append("")

    sections = tour.get("sections") or []
    ordered = ordered_sections(tour)
    groups = tour.get("groups") or []

    if groups:
        out.append(c("bold") + "Contents" + c("reset"))
        by_id = {}
        for i, s in enumerate(sections):
            if isinstance(s, dict):
                by_id[s.get("id") or ("section-%d" % i)] = s
        number_by_id = {e["section"].get("id"): e["number"] for e in ordered}
        for group in groups:
            out.append("  " + c("head") + group_name(group) + c("reset"))
            if group.get("description"):
                out.append("    " + c("dim")
                           + _ansi_inline(tour, None, group.get("description"), color)
                           + c("reset"))
            for sid in group.get("sections") or []:
                s = by_id.get(sid)
                if not s:
                    continue
                out.append("    %s. %s" % (number_by_id.get(sid, ""), s.get("title", "")))
        orphans = [e for e in ordered if not e["group"]]
        if orphans:
            out.append("  " + c("head") + "Other" + c("reset"))
            for e in orphans:
                out.append("    %s. %s" % (e["number"], e["section"].get("title", "")))
        out.append("")

    for entry in ordered:
        s = entry["section"]
        num = entry["number"]
        if entry["group_start"]:
            group = entry["group"]
            out.append(c("title") + group_name(group) + c("reset"))
            if group.get("description"):
                out.append(c("dim")
                           + _ansi_inline(tour, None, group.get("description"), color)
                           + c("reset"))
            out.append("")
        loc = ""
        if s.get("file") and s.get("lineStart"):
            web = bool(tour.get("webUrlBase"))
            loc = "  " + c("dim") + _ref_label(s["file"], s["lineStart"],
                                               s.get("lineEnd"), web) + c("reset")
        elif s.get("file"):
            loc = "  " + c("dim") + s["file"] + c("reset")
        out.append(c("head") + ("%s. " % num)
                   + _ansi_inline(tour, s.get("file"), s.get("title", ""), color)
                   + c("reset") + loc)
        out.append("")
        _ansi_block(tour, s.get("file"), s.get("body"), out, color)
        if s.get("code"):
            for line in str(s["code"]).split("\n"):
                out.append(c("code") + "    " + line + c("reset"))
            out.append("")
        for callout in s.get("callouts") or []:
            kind = callout.get("type", "info")
            label = _CALLOUT_LABEL.get(kind, "")
            out.append(c(kind if kind in _ANSI else "info")
                       + "  " + label + _ansi_inline(tour, s.get("file"),
                                                     callout.get("text", ""), color)
                       + c("reset"))
        if s.get("callouts"):
            out.append("")
        diagrams(s.get("diagrams"))
        anchors = s.get("anchors") or []
        if anchors:
            web = bool(tour.get("webUrlBase"))
            jumps = []
            for an in anchors:
                af = an.get("file") or s.get("file")
                lab = an.get("label") or _ref_label(af, an["lineStart"],
                                                     an.get("lineEnd"), web)
                jumps.append(lab)
            out.append("  " + c("dim") + "Jump to: " + " \u00b7 ".join(jumps) + c("reset"))
            out.append("")

    if tour.get("dataFlow"):
        out.append(c("head") + "Data flow" + c("reset"))
        out.append("")
        _ansi_block(tour, None, tour.get("dataFlow"), out, color)

    return "\n".join(out).rstrip() + "\n"


# --------------------------------------------------------------------------- #
# Output helpers
# --------------------------------------------------------------------------- #

_EXT = {"html": "-tour.html", "md": "-tour.md", "cli": "-tour.txt"}


def default_output(source, fmt):
    base = "tour"
    if source and source != "-":
        base = os.path.splitext(os.path.basename(source))[0]
        for suffix in ("-tour", ".tour", "_tour"):
            if base.endswith(suffix):
                base = base[: -len(suffix)]
                break
    return base + _EXT[fmt]


def copy_mermaid_assets(template_path: str, out_path: str) -> list:
    """Copy the local Mermaid runtime next to an HTML tour that uses diagrams.

    The assets live beside the template; they are copied next to the output so
    the tour's ``import './mermaid.esm.min.mjs'`` resolves and renders offline.
    """
    src_dir = os.path.dirname(os.path.abspath(template_path))
    dst_dir = os.path.dirname(os.path.abspath(out_path))
    copied = []
    for name in _MERMAID_ASSETS:
        src = os.path.join(src_dir, name)
        if not os.path.isfile(src):
            raise TourError(
                "tour uses diagrams but Mermaid runtime is missing next to the "
                "template: %s" % src)
        dst = os.path.join(dst_dir, name)
        if os.path.abspath(src) != os.path.abspath(dst):
            shutil.copy2(src, dst)
        copied.append(name)
    return copied


def write_output(path: str, content: str, force: bool) -> None:
    if os.path.exists(path) and not force:
        raise TourError(
            "refusing to overwrite existing file (pass --force to allow): %s" % path
        )
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)


# --------------------------------------------------------------------------- #
# CLI entry point
# --------------------------------------------------------------------------- #

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate a code-tour JSON document and render it to "
                    "HTML, Markdown, or CLI text.")
    parser.add_argument("tour", help="path to the tour JSON ('-' for stdin)")
    parser.add_argument("--format", "-f", choices=("html", "md", "cli"),
                        default="html", help="output format (default: html)")
    parser.add_argument("--output", "-o",
                        help="output path (default: derived from the input name; "
                             "stdout for cli)")
    parser.add_argument("--template", "-t", default=_DEFAULT_TEMPLATE,
                        help="HTML template path (default: shipped template)")
    parser.add_argument("--force", action="store_true",
                        help="overwrite the output file if it already exists")
    parser.add_argument("--no-color", action="store_true",
                        help="disable ANSI color in cli format")
    parser.add_argument("--validate-only", action="store_true",
                        help="validate the tour and exit without rendering")
    args = parser.parse_args(argv)

    try:
        tour = load_tour(args.tour)
        validate_tour(tour)

        if args.validate_only:
            sys.stderr.write("OK: tour is valid (%d sections, %d files)\n"
                             % (len(tour.get("sections") or []),
                                len(tour.get("files") or {})))
            return 0

        if args.format == "html":
            content = render_html(tour, args.template)
        elif args.format == "md":
            content = render_markdown(tour)
        else:
            content = render_cli(tour, color=not args.no_color)

        if args.format == "cli" and not args.output:
            sys.stdout.write(content)
            return 0

        out_path = args.output or default_output(args.tour, args.format)
        write_output(out_path, content, args.force)
        sys.stderr.write(
            "Wrote %s (%s, %d sections, %d files)\n"
            % (out_path, args.format, len(tour.get("sections") or []),
               len(tour.get("files") or {}))
        )
        if args.format == "html" and tour_has_diagrams(tour):
            names = copy_mermaid_assets(args.template, out_path)
            sys.stderr.write(
                "Copied Mermaid runtime next to the tour: %s\n" % ", ".join(names))
        sys.stdout.write(out_path + "\n")
        return 0
    except TourError as exc:
        sys.stderr.write("error: %s\n" % exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
