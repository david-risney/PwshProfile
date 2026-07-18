# Touring PRs, diffs, and git commits

The tour JSON is source-agnostic: a section is just a file name plus line
numbers plus prose. What changes for a pull request, a diff, or an arbitrary
commit is only **(a) where you read the code from** and **(b) what web links the
badges point at**. This note covers both. See `tour-schema.md` →
*Linking sources* for the field reference.

## The golden rule: line numbers must match the source you link to

Every `lineStart` / `lineEnd` / `[[...]]` must match the file **at the exact
revision the links open**. The safest way to guarantee this is to tour the
**full file content at one pinned commit** and point the links at that same
commit. Do **not** mix "line numbers read from my local checkout" with "links to
the PR head" — if the local branch differs, every badge is silently off.

- Prefer a **pinned commit SHA** (the PR's source/head commit) over a branch
  name in both the content you read and the URL template. Branches move; a tour
  built against `main` rots the moment `main` advances.
- Whole-file (not just the diff hunks) is usually the right unit: reviewers want
  the surrounding function, and whole-file line numbers are unambiguous. Treat
  "the diff" as *what to talk about*, not *what to read* — read the whole file,
  then write sections and callouts about the changed ranges.

## Workflow for a pull request

1. **Resolve the PR to a commit and a file list.** Get the PR's source (head)
   commit SHA and the set of changed files. Keep the SHA — it pins both content
   and links.
2. **Fetch each changed file's full content at that SHA.** Read it the way you
   would a local file (derive the line map, pick section ranges). Fetch by
   commit, not by branch.
3. **Choose a link template** for the host (see below) using the same SHA.
4. **Write the JSON** exactly as for a local tour — sections reference the
   line numbers you just read. Set `webUrlTemplate` + each file's `webPath`
   (repo-relative path) instead of local `path`s.
5. **Validate + render + verify** as usual (see `SKILL.md`).

If a file is **added** in the PR, it only exists at the PR commit — fetch it
from that commit, not from the base branch (it will 404 on the base).

### Azure DevOps (ADO)

Fetch file content at a commit via the Git Items REST API:

```
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/items
      ?path={/repo/relative/path}
      &versionDescriptor.version={commitSha}
      &versionDescriptor.versionType=commit
      &includeContent=true
      &$format=json
      &api-version=7.1
```

The file text is the `content` field of the JSON response. Two gotchas seen in
practice:

- **`$format=json` + `Accept: application/json`** — otherwise the API may return
  raw text and your `content` field is empty.
- **The `&` in the query string.** When calling through `az rest` on Windows,
  `az.cmd` hands the URL to `cmd.exe`, which splits on `&` and drops every query
  param after the first — you silently get tip-of-default-branch instead of your
  commit. Use `Invoke-RestMethod` with a bearer token
  (`az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798`)
  and pass the whole URL as one quoted string, or otherwise ensure `&` is not
  re-parsed by a shell.

ADO web link template (ADO needs a line **range** and ignores `#L` fragments):

```
https://dev.azure.com/{org}/{project}/_git/{repo}/commit/{sha}?path={path}&line={line}&lineEnd={lineEnd}&lineStartColumn=1&lineEndColumn=1&type=1
```

Put it in `webUrlTemplate`; set each file's `webPath` to its repo-relative path
(e.g. `/chrome/browser/.../foo.cc`). ADO accepts raw `/` in the `path=` value.

### GitHub

Fetch content with the CLI (`gh api repos/{owner}/{repo}/contents/{path}?ref={sha}`
— base64-decode `.content`) or raw
(`https://raw.githubusercontent.com/{owner}/{repo}/{sha}/{path}`). Web link
template (GitHub supports `#L{a}-L{b}` ranges directly):

```
https://github.com/{owner}/{repo}/blob/{sha}{path}#L{line}-L{lineEnd}
```

Here `{path}` is part of the URL **path**, so `webPath` must start with `/` and
use raw slashes (do not pre-encode).

## Touring a diff or an arbitrary git commit

Same idea, two flavors:

- **A commit** (`<sha>`): tour the files **as of that commit** — read each file
  at `<sha>` (`git show <sha>:<path>` locally, or the host API above) and point
  `webUrlTemplate` at `<sha>`. This describes the post-commit state, which is
  what the commit's line numbers refer to.
- **A diff / two-dot range** (`<base>..<head>`): decide up front which side you
  are narrating.
  - *After* state (most common): read files at `<head>` and link to `<head>`.
    Use callouts to say "this block is new / changed"; there is no in-viewer red
    (`-`) / green (`+`) gutter — the shipped renderer shows files, not hunks.
  - *Before* state: read and link at `<base>` instead.
  - Get the changed-file list from `git diff --name-status <base> <head>` (or the
    host's PR "changes" API) and the hunk ranges from `git diff -U0` to know
    which line ranges to write sections/callouts about.

To call out a specific added range, still use whole-file line numbers (from the
side you read) in `lineStart`/`lineEnd` and a `callout` explaining it changed —
e.g. *"Lines [[124-135]] are new in this PR: the on-sequence adopt step."*

## Local + web in the same tour

Fill both `path` (absolute local) and `webPath` on a file entry. With no web
template set, badges are editor links; add a `webUrlTemplate` (or render a
second copy for sharing) to flip the whole tour to web links without touching
any section. Per-file `url` overrides the global template for one odd file
(e.g. a vendored header that lives elsewhere).

## Checklist specific to remote tours

- [ ] Content was read at the **same SHA** the links point to.
- [ ] Added files were fetched from the **PR/commit**, not the base branch.
- [ ] `webPath` values are **repo-relative** and match the host's expectation
      (leading `/`; raw slashes).
- [ ] The link template uses `{line}` (and `{lineEnd}` where the host needs a
      range).
- [ ] You told the user that some hosts (ADO) open the file/version but may not
      scroll to the exact line.
