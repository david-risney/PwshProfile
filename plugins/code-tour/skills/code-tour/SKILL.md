---
name: code-tour
description: "Generate a 'code tour': a declarative JSON walkthrough of source code (sections, line ranges, prose) that renders to a self-contained HTML viewer with jump-to-editor links, Markdown, or ANSI CLI text (HTML by default). Use when asked to 'create a code tour', 'make a code walkthrough', 'guided tour of this file', 'explain this code with jump links', 'walk me through this script', or 'document how this file works visually'."
---

# Code Tour

Walk a reader through source code, section by section, with references that
point to the exact lines. The reader opens the result side-by-side with the
code.

The skill separates **content** from **presentation**:

- **Content** is a declarative JSON *tour* document you generate
  (see `references/tour-schema.md`). It holds only structure and prose —
  sections, line ranges, callouts, and `[[line]]` references. No HTML, no
  colors, no escape codes. **The JSON is the real artifact.**
- **Presentation** is a *renderer* that consumes that JSON. The default is the
  shipped HTML viewer (`assets/tour-template.html`), which produces a single
  self-contained HTML file with jump-to-editor links. The same JSON can also be
  rendered as a **Markdown** document or **ANSI-colored CLI** text.

You always write JSON first; the bundled renderer script
(`scripts/build_tour.py`) turns it into the requested output. Line numbers live
in the JSON as data — never hand-write HTML or scatter line numbers through
markup. **Generating the JSON is the only step that requires you (the AI);**
validation, template filling, file copying, and rendering are all done by the
script.

## When to use

Activate when the user asks to create a code tour / walkthrough / guided
explanation of a file or area of code, especially when they want clickable
jump-to-line links or a visual, side-by-side reading aid.

## Inputs

- **Target**: one or more files, or a feature/area the user names. If the target
  is ambiguous (e.g. "tour the auth code"), identify the most relevant files
  first, then confirm scope with the user if it is large.
- **Editor**: default to VS Code (`vscode://`). Use `vscode-insiders` only if
  the user says so. Use a web URL (`webUrlBase`) only if the user explicitly
  wants GitHub/ADO links.
- **Absolute paths**: editor links need each file's absolute path. Resolve it
  for every file you include (e.g. via the repo root + relative path).

## Requirements

The renderer script (`scripts/build_tour.py`) needs **Python 3.8 or newer**
(it is pure standard library — no `pip install` step). Generating the JSON tour
needs only you (the AI); every other step runs through this script, so Python
must be available before you render.

- **Invocation differs by platform.** On Windows use the launcher `py -3`; on
  macOS/Linux use `python3`. (Plain `python` may be Python 2 or missing — on
  this machine `python` is Python 2.7, so always use `py -3` here.)
- **Check it first.** Run `py -3 --version` (Windows) or `python3 --version`
  (elsewhere) and confirm it reports `Python 3.8+`.
- **If Python is missing, install it — prefer winget on Windows:**

  ```powershell
  # Windows (preferred): installs the latest Python 3 + the `py` launcher
  winget install --id Python.Python.3.12 -e --source winget
  ```

  If winget is unavailable, download an installer from
  <https://www.python.org/downloads/> (on Windows, tick "Add python.exe to
  PATH" / "py launcher"). On macOS use `brew install python`; on Debian/Ubuntu
  use `sudo apt install python3`. After installing, open a fresh shell and
  re-check the version before rendering.

## Workflow

1. **Read the code.** Read each target file fully enough to explain it. For
   large files, read in ranges.

2. **Build an accurate line map.** Derive the line ranges for each section
   (function, class, constant block, comment, etc.). A quick way to get a
   symbol map is to list definition lines, then read each range for sub-line
   anchors:
   - Python/JS/TS: search for lines beginning with `def `, `class `, `function `,
     `const `, `export `, etc., and note their line numbers.
   - Record, per section: the start line, the end line, and any specific lines
     worth an inline badge (a key branch, a guard, a return).
   - **Re-derive the map after any code edit** — inserting or deleting lines
     shifts every line number below the change. Stale line numbers are the most
     common defect in a tour.

3. **Write the JSON tour.** Follow `references/tour-schema.md`. Guidelines:
   - One section per meaningful unit. Order them top-to-bottom through the file
     (or in reading order across files).
   - Give every section a unique kebab-case `id`.
   - Put the section's overall range in `lineStart`/`lineEnd` (renders a heading
     badge). Reference specific interior lines from prose with inline
     `[[start]]` / `[[start-end]]` badges — they read naturally and keep the
     line numbers in the data.
   - Use `code` only for the few lines that matter; it renders verbatim (it is
     NOT a place to paste the whole function).
   - Use `callouts` (`good` / `warn` / `danger` / default) for "why", gotchas,
     and security/design notes. Use `designNotes` for top-level structure notes.
   - `diagrams` (Mermaid) are **optional** — you do not have to add any. Only
     add one when there is a non-obvious diagram you can create accurately;
     otherwise omit diagrams entirely. When you do add them, attach to the
     `intro` or any section where a picture genuinely helps — control/data flow,
     state machines, sequence/architecture. Each entry is a Mermaid string or
     `{ "title": "...", "code": "graph TD ..." }`. Keep them small; the source
     is data, not markup. Two hard rules:
     - **Only add non-obvious diagrams.** A diagram must reveal structure the
       reader can't see at a glance — a non-trivial control/data flow, state
       machine, or cross-component interaction. Good examples: a **class
       diagram** showing how multiple classes connect and through which
       members, or a **call graph** showing which methods call which across
       files. Do **not** diagram a linear sequence of steps, a trivial call, or
       anything the prose already makes clear. When in doubt, leave it out.
     - **Only add accurate diagrams.** Every node, edge, and label must match
       the actual code (real function names, real branches, real ordering).
       A wrong diagram is worse than none — never guess or invent flow.
   - Add a `dataFlow` summary when the file has a clear end-to-end flow.
   - Group related sections with the optional top-level `groups` array: each
     group has a `title`, a short `description`, and an ordered list of section
     `id`s. Sections that share a logical purpose (setup, core logic, I/O, etc.)
     should be grouped together. Groups render as the top table of contents and
     as a banner before each group's first section; ungrouped sections fall
     under an "Other" heading. Keep `sections` flat — a group only references ids.
   - Keep prose tight and concrete; explain intent and tradeoffs, not the
     obvious syntax.

4. **Validate and render with the script.** You do **not** hand-fill the HTML
   template, hand-write Markdown/CLI output, or manually copy files. A bundled
   script (`scripts/build_tour.py`, pure standard-library Python 3) performs
   every deterministic step: it validates the JSON, fills the HTML template
   (escaping any literal `</script>`), or renders Markdown / ANSI CLI text, and
   writes the output file. When the tour has Mermaid `diagrams`, the script also
   copies the bundled local Mermaid runtime (`mermaid.esm.min.mjs` +
   `mermaid.min.js`) next to the HTML so it renders offline. Your only authored
   artifact is the JSON tour.

   Write the JSON tour to a file (e.g. `<basename>.tour.json`), then run:

   ```sh
   # HTML (default). Use `py -3` on Windows, `python3` elsewhere.
   python3 scripts/build_tour.py <basename>.tour.json
   # Markdown:
   python3 scripts/build_tour.py <basename>.tour.json --format md
   # ANSI CLI text (to stdout):
   python3 scripts/build_tour.py <basename>.tour.json --format cli
   ```

   Useful flags:
   - `--output PATH` — explicit output path (default: `<input>-tour.html`/`.md`/
     `.txt`; CLI prints to stdout when omitted).
   - `--force` — allow overwriting an existing output file. The script refuses
     to clobber without it, so confirm with the user first.
   - `--validate-only` — check the JSON (parse, unique ids, every referenced
     file declared in `files`, `lineStart <= lineEnd`, and — when the file is on
     disk — line ranges within the file) and exit without rendering.
   - `--template PATH` — override the HTML template (defaults to the shipped
     `assets/tour-template.html`).

   The script exits non-zero and prints precise messages on any validation
   failure. Fix the JSON and re-run; do not work around it by editing output by
   hand. On success it prints the output path. The JSON remains the single
   source of truth for every format.

## Output rules

- The JSON tour is the source artifact; the requested rendering (HTML by
  default) is derived from it by `scripts/build_tour.py`. Don't hand-author the
  rendered output separately.
- For the HTML deliverable, the script embeds the JSON into the template — no
  separate `.json` sidecar in the final output unless the user asks for it (a
  working `*.tour.json` you pass to the script is fine and expected).
- Never invent line numbers or symbols — every reference must match the actual
  source you read.
- Do not edit the source code being toured. This skill documents code; it does
  not change it.
- Never hand-edit the rendered HTML/Markdown/CLI output or the template; the
  script keeps the template byte-for-byte intact except for the single
  placeholder substitution, so the viewer stays reviewable and reusable.

## Tips learned from real tours

- The biggest maintenance cost is line drift. If you edit the toured file (or it
  changes between runs), regenerate the line map and re-emit the JSON; do not
  patch numbers piecemeal.
- Prefer inline `[[...]]` badges over a separate `anchors` list when the line
  reference belongs in a sentence.
- A good tour has a short `intro`, an honest `designNotes`/`callouts` voice
  (including caveats and "why not X"), and a closing `dataFlow`.

## Security Boundaries

**This skill:**
- **CAN**: Read source files and repository metadata to describe them; generate
  a JSON tour document (including Mermaid `diagrams`); run the bundled
  `scripts/build_tour.py` to validate the JSON, fill the shipped HTML template
  (substituting the `__TOUR_JSON__` placeholder), render Markdown/CLI output,
  copy the bundled local Mermaid runtime next to an HTML tour that uses
  diagrams, and write the result to the workspace.
- **CANNOT**: Modify the source code being toured; modify the viewer template
  beyond the single placeholder substitution the script performs; fetch remote
  resources or add third-party/CDN dependencies to the output (the Mermaid
  runtime is bundled and copied locally — the result must stay
  self-contained and offline); fabricate line numbers, symbols, or file paths;
  embed executable content beyond the template's own fixed renderer.
- **MUST CONFIRM**: Before overwriting an existing output file, and before
  generating a large multi-file tour when the requested scope is ambiguous.
