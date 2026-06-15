# Tour JSON schema

A *tour* is a single **declarative JSON document** describing a guided
walkthrough of code. The JSON is the real artifact — it holds **content and
structure only, never presentation**. A *renderer* turns it into a concrete
output:

- the shipped **HTML viewer** (`assets/tour-template.html`, the default
  renderer — embeds the JSON at its `__TOUR_JSON__` placeholder),
- a **Markdown** document, or
- **ANSI-colored text** for the CLI.

So the JSON never contains HTML, colors, or escape codes. It describes *what* a
section is (its lines, prose, and the semantic kind of each callout); each
renderer decides *how* to present it — e.g. a line reference becomes a
`vscode://` link in HTML, a `path#L12` link in Markdown, or `path:12` text on
the CLI. Line numbers are **data**, never hand-written markup.

## Top-level fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `title` | string | yes | Shown in the header and the document title. |
| `subtitle` | string | no | One line under the title. |
| `files` | object | yes | Maps each logical file name used in sections to its **absolute path**. A renderer uses this to build line references (editor link, web link, or plain `path:line` text). e.g. `{ "publish.py": "C:/repo/publish.py" }`. |
| `editor` | string | no | Link hint: `"vscode"` (default) or `"vscode-insiders"`. Renderers that emit clickable editor links use it; text/Markdown renderers may ignore it. |
| `webUrlBase` | string | no | Link hint: if set, line references resolve to `webUrlBase + <file> + "#L<line>"` (GitHub/ADO-style) instead of an editor link. |
| `intro` | string (markdown) | no | Overview shown before the list of sections. |
| `diagrams` | Diagram[] | no | Mermaid diagrams shown with the intro (see **Diagram**). |
| `designNotes` | string[] (markdown) | no | Top-level structural / "why it's shaped this way" notes, one per entry. A renderer may present them as a grouped callout. |
| `sections` | Section[] | yes | The ordered walkthrough. |
| `groups` | Group[] | no | Optional grouping of sections into a top-level table of contents (see **Group**). Sections stay flat in `sections`; a group only references their ids. |
| `dataFlow` | string (markdown) | no | A closing "how it fits together" summary. |

## Section

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `id` | string | yes | Stable anchor id (kebab-case). Must be unique. |
| `number` | integer | no | Display number. Defaults to position (1-based). |
| `title` | string (markdown inline) | yes | Heading text. |
| `file` | string | yes* | Logical file name (a key in `files`). Required if the section has line links. |
| `lineStart` | integer | no | First line of the section's range; renders a badge in the heading. |
| `lineEnd` | integer | no | Last line of the range (omit for a single line). |
| `body` | string (markdown) | no | The explanation. |
| `code` | string | no | A short verbatim excerpt of the lines that matter. Treated as literal text (a renderer shows it as-is, never interpreting it as markup). Keep it to the few lines that matter, not the whole unit. |
| `callouts` | Callout[] | no | Highlighted notes with a semantic kind (see below). |
| `diagrams` | Diagram[] | no | Mermaid diagrams for this section (see **Diagram**). |
| `anchors` | Anchor[] | no | Extra labeled line references below the body (for sub-line jumps). Prefer inline `[[...]]` references in `body` instead, when natural. |

\* `file` is only optional for purely narrative sections with no line links.

## Group

A *group* bundles related sections under a shared heading. Groups are optional
and purely organizational: `sections` remains the flat source of truth, and a
group only lists the **ids** of the sections it contains. When any groups are
present, renderers show a grouped table of contents at the top (each group's
name + description, then its section links) and emit a banner before each
group's first section. Sections are numbered by their final rendered order, so
the numbers in the TOC and the headings always match.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `id` | string | no | Stable anchor id for the group heading (kebab-case). Must be unique when present. |
| `title` | string | yes | The group's display name. `name` is accepted as an alias. |
| `description` | string (markdown inline) | no | A short one-line summary shown under the group name. |
| `sections` | string[] | yes | Ordered list of section `id`s in this group. Every id must exist in `sections`, and no section may appear in more than one group. |

Sections referenced by a group are rendered in the group's listed order, then
any sections not referenced by any group follow (in their original `sections`
order) under an "Other" heading.

## Diagram

A diagram is a [Mermaid](https://mermaid.js.org) graph attached to the `intro`
or to a section. It is either a **string** (the raw Mermaid source) or an
**object**:

| Field | Type | Notes |
|-------|------|-------|
| `code` | string | Required. The Mermaid source (e.g. a `graph TD` / `flowchart LR` / `sequenceDiagram` body). `mermaid` is accepted as an alias. |
| `title` | string | Optional caption shown above the diagram. |

The Mermaid source is **data**, never markup — renderers never interpret it as
HTML. Each renderer presents diagrams differently:

- **HTML:** each diagram becomes a `<pre class="mermaid">` block that the bundled
  local Mermaid runtime (`mermaid.esm.min.mjs`, copied next to the output) turns
  into an SVG. If Mermaid cannot load, the source stays visible as text.
- **Markdown:** a fenced ` ```mermaid ` code block (rendered by GitHub and other
  Mermaid-aware viewers).
- **CLI:** the Mermaid source printed verbatim in a labeled box (terminals can't
  draw the graph).

## Callout

| Field | Type | Notes |
|-------|------|-------|
| `type` | string | Semantic kind: `"info"` (default), `"good"`, `"warn"`, or `"danger"`. A renderer maps each kind to its own presentation (HTML color, Markdown prefix, ANSI color). |
| `text` | string (markdown) | Callout body. |

## Anchor

| Field | Type | Notes |
|-------|------|-------|
| `lineStart` | integer | Required. |
| `lineEnd` | integer | Optional (range). |
| `label` | string | Optional; defaults to `line N` / `lines N–M`. |
| `file` | string | Optional; defaults to the section's `file`. |

## Markdown subset

Text fields (`intro`, `body`, callout `text`, `designNotes`, `dataFlow`) use a
small, portable Markdown subset that any renderer can map to its target
(HTML, Markdown, or ANSI text):

- `` `code` `` → inline code
- `**bold**` → bold
- `[label](url)` → link (http/https/vscode schemes only)
- Blank line → new paragraph
- Lines starting with `- ` → bullet list
- **`[[12]]`** or **`[[12-20]]`** → a line reference for the section's `file`
- **`[[publish.py:12-20]]`** → a line reference for an explicit file (any key in
  `files`)

The `[[...]]` token is the renderer-agnostic way to reference lines from inside
prose: the HTML renderer turns it into a clickable badge, a Markdown renderer
into a `path#L12` link, a CLI renderer into `path:12` text. Keeping line numbers
as `[[...]]` tokens (not hand-written links) is what lets one JSON drive every
output.

## Minimal example

```json
{
  "title": "publish.py — guided walkthrough",
  "files": { "publish.py": "C:/Users/me/repo/publish.py" },
  "editor": "vscode",
  "intro": "`publish.py` turns the `staged/` tree into the published `plugins/` tree.",
  "sections": [
    {
      "id": "resolvesource",
      "number": 6,
      "title": "_resolve_ref_source — the containment choke point",
      "file": "publish.py",
      "lineStart": 112,
      "lineEnd": 139,
      "body": "Turns the path named in a `.file-ref` into a candidate and contains it to the repo. The absolute-path rejection is at [[129-132]] and the containment check at [[135-138]].",
      "callouts": [
        { "type": "good", "text": "`resolve()` collapses `..` before the check, so a relative ref can't climb out of the repo." }
      ]
    }
  ],
  "dataFlow": "**cmd_write** → **build_published_plugin** → **_resolve_ref_source** (the lone path-traversal guard) → **_copy_real_file**."
}
```

See `example-tour.json` for a complete, multi-section example.
