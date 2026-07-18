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

- **Target**: one or more files, or a feature/area the user names. The source can
  be **local files** or a **pull request / commit / diff** (not checked out
  locally). If the target is ambiguous (e.g. "tour the auth code"), identify the
  most relevant files first, then confirm scope with the user if it is large.
- **Link mode**: decide where badges should open.
  - *Local* (default): editor links via `vscode://` (`vscode-insiders` only if
    the user says so). `files` values are absolute local paths.
  - *Web* (PRs/commits): set `webUrlTemplate` (one base for the whole tour) and
    give each file a `webPath`; badges open the file at that revision on the web
    host. See `references/pr-and-diff-sources.md`.
- **Paths**: editor links need each file's absolute local path; web links need
  each file's repo-relative `webPath`. A file entry may carry both. Resolve the
  right one for every file you include (e.g. repo root + relative path, or the
  PR's changed-file list). See `references/tour-schema.md` → *Linking sources*.

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
   large files, read in ranges. **Line numbers must match the exact revision the
   links will open.** For a PR / commit / diff that is not checked out, read the
   **full file content at the pinned commit SHA** (not the local branch, not the
   diff hunks alone) and link to that same SHA — see
   `references/pr-and-diff-sources.md` for how to fetch content and build the
   `webUrlTemplate` for ADO or GitHub.

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
   - Use `seeAlso` for **further reading** a reader needs to understand the
     section: functions, language features, or patterns that are *integral to
     the code and not widely known* — worth a short detour. Examples: an
     uncommon library type (`std::optional`, `base::WeakPtr`), or a
     concurrency/annotation pattern the change relies on (sequences,
     `GUARDED_BY_CONTEXT`, `SEQUENCE_CHECKER`). Skip the obvious; a few
     high-value topics beat a long list. Each entry is `{ topic, links[] }`;
     a link is a URL string or `{ label, url }`. Prefer link targets in this
     order: **in-project docs**, then a **header/source file whose comments
     explain the concept** (or, failing that, the definition itself), then an
     **authoritative web reference**.
   - `diagrams` (Mermaid) are **optional** — you do not have to add any. Only
     add one when there is a non-obvious diagram you can create accurately;
     otherwise omit diagrams entirely. When you do add them, attach to the
     `intro` or any section where a picture genuinely helps — control/data flow,
     state machines, sequence/architecture. Each entry is a Mermaid string or
     `{ "title": "...", "code": "graph TD ..." }`. Keep them small; the source
     is data, not markup. Apply this decision test, then the two hard rules:
     - **Decision test — does it cross a boundary the reader can't see in one
       place?** Diagram-worthiness is about *span*, not whether the flow is
       linear. Add a diagram when the structure spans things a reader cannot
       hold in their head from a single screen: multiple files, processes,
       threads, layers, or components; an IPC/Mojo or network hop; an async
       hand-off (callback, observer, posted task, message); or 3+ collaborating
       types. A flow that is "linear" but threads through renderer → IPC →
       browser → another object across many files **is** diagram-worthy — the
       hops are the non-obvious part. Concretely, lean toward a diagram when the
       tour touches **~4+ files** or **crosses a process/IPC boundary**, even if
       each individual step is simple. Conversely, a flow that stays inside one
       file or one function — however many steps — usually is not.
       - *Worked example (do add):* a feature where a renderer plugin reads a
         value, sends it over Mojo, a browser-side host forwards it to a
         connector, the connector performs an action and caches a result, and a
         fourth object reads that result back through a delegate. Two small
         diagrams capture it well: a **sequence diagram** of the write path
         (renderer → Mojo → host → connector → action) and a **call graph** of
         the read path (caller → delegate accessor → connector getter). Each
         crosses process and object boundaries the prose can only describe one
         hop at a time.
       - *Counter-example (do not add):* a single function that validates input,
         transforms it, and returns — the prose and `code` snippets already make
         the order clear.
     - **Only add non-obvious diagrams.** A diagram must reveal structure the
       reader can't see at a glance — a non-trivial control/data flow, state
       machine, or cross-component interaction. Good examples: a **class
       diagram** showing how multiple classes connect and through which
       members, a **call graph** showing which methods call which across files,
       or a **sequence diagram** of a cross-process/async hand-off. Do **not**
       diagram a trivial call, or a single-file/single-function step sequence
       the prose already makes clear. When in doubt, apply the decision test
       above; if it still ties, leave it out.
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
     obvious syntax. Follow the **Writing style** section below.

4. **Validate and render with the script.** You do **not** hand-fill the HTML
   template, hand-write Markdown/CLI output, or manually copy files. A bundled
   script (`scripts/build_tour.py`, pure standard-library Python 3) performs
   every deterministic step: it validates the JSON, fills the HTML template
   (escaping any literal `</script>`), or renders Markdown / ANSI CLI text, and
   writes the output file. When the tour has Mermaid `diagrams`, the script also
   embeds the bundled local Mermaid runtime (`mermaid.min.js`) inline into the
   HTML so it renders offline as a single self-contained file (no sidecar
   assets). Your only authored artifact is the JSON tour.

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

## Writing style

All prose in a tour — `intro`, `body`, `callouts`, `designNotes`, `dataFlow`,
topic labels — is **technical writing**. Optimize for clarity, concision,
accuracy, and honesty:

- **Clear.** Plain, direct sentences. Explain the *why* and the tradeoff a
  reader can't see in the code; name the concept, then point at the line.
- **Concise.** Cut filler. No throat-clearing ("It is worth noting that…"), no
  restating the code in English. Prefer the shortest wording that stays precise.
- **Accurate.** Every claim must match the code you actually read — real symbols,
  real ordering, real behavior. If you are unsure, say so or leave it out; never
  guess or embellish.
- **Honest.** Include caveats, gotchas, and "why not X". A `warn`/`danger`
  callout that names a real hazard is worth more than praise. Don't oversell a
  change or paper over a limitation.

Never write in a voice that is cutesy, corporate, verbose, patronizing, or
hype-y. Avoid marketing adjectives ("blazing-fast", "robust", "seamless",
"powerful"), exclamation points, emoji, and cheerleading. State what the code
does and why; let the facts carry it.

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
- **CAN**: Read source files and repository metadata to describe them —
  including fetching file content for a PR / commit from a code host's read-only
  API when the source is not checked out locally; generate a JSON tour document
  (including Mermaid `diagrams`); run the bundled `scripts/build_tour.py` to
  validate the JSON, fill the shipped HTML template (substituting the
  `__TOUR_JSON__` placeholder), render Markdown/CLI output, embed the bundled
  local Mermaid runtime inline into an HTML tour that uses diagrams, and write
  the result to the workspace.
- **CANNOT**: Modify the source code being toured; modify the viewer template
  beyond the single placeholder substitution the script performs; make the
  **generated output** depend on remote resources or third-party/CDN assets (the
  Mermaid runtime is bundled and copied locally — the result must stay
  self-contained and work offline; link *targets* like PR URLs are fine, but
  nothing the viewer needs to render may be remote); fabricate line numbers,
  symbols, or file paths; embed executable content beyond the template's own
  fixed renderer.
- **MUST CONFIRM**: Before overwriting an existing output file, and before
  generating a large multi-file tour when the requested scope is ambiguous.
