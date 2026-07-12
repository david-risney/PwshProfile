<#
.SYNOPSIS
    Find, create, or fork GitHub Copilot CLI sessions. Search existing sessions
    by working-directory path, repository (owner/name or git URL), branch, or
    name.

.DESCRIPTION
    Copilot CLI persists every session under
    %USERPROFILE%\.copilot\session-state\<id>\, and each folder has a
    `workspace.yaml` describing it (id, cwd, git_root, repository, branch, name,
    created_at, updated_at, mc_* remote ids). This script reads those files
    directly -- it never needs the CLI running -- to let you:

      * Find   -- list/search sessions by -Path / -Repository / -Branch / -Name.
                  Also surfaces cloud/agent sessions synced to disk (no
                  workspace.yaml); use -LocalOnly to hide them.
      * New    -- start a fresh session (prints, or with -Launch opens, the
                  `copilot` command; supports -Name, -WorkingDirectory).
      * Fork   -- clone an existing session into a NEW, fully independent session
                  (new id, remote-attach ids stripped) so you can branch off its
                  history without disturbing the original.
      * Sync   -- pull a cloud/remote session or task down for local use by
                  resuming (`--resume`) or attaching (`--connect`) to its id.

    On "official fork": there is NO dedicated `copilot fork` command. The CLI's
    `--resume`, `--continue`, `--connect`, and `--session-id` flags only *resume
    or attach to* an existing session -- resuming the same id keeps writing to
    the same history. Forking therefore means duplicating the session folder and
    rewriting its identifiers, which is what -Action Fork does here.

.PARAMETER Action
    Find (default), New, Fork, or Sync.

.PARAMETER Path
    Filter/target by working directory. Substring-matched (case-insensitive)
    against each session's cwd and git_root. Use '.' for the current directory.
    For -Action New, the directory to start the session in.

.PARAMETER Repository
    Filter by repository. Substring-matched against the session's `repository`
    field (e.g. "microsoft/Edge/edge-agents"). A full git URL is accepted and
    reduced to its owner/name path before matching.

.PARAMETER Branch
    Filter/target by branch. Substring-matched (case-insensitive). For -Action
    Fork, also overrides the fork's branch in workspace.yaml.

.PARAMETER Name
    Filter by session name (substring, case-insensitive). For New/Fork, use
    -NewName to set the created session's name.

.PARAMETER Session
    Explicit session selector. For -Action Fork: a full id, an id prefix (7+ hex
    chars), or an exact session name. For -Action Sync: the cloud session id,
    task id, id prefix, or name to pull down locally.

.PARAMETER NewName
    Name to assign to the new/forked session.

.PARAMETER WorkingDirectory
    For -Action New: directory to start the session in (default: current dir).
    For -Action Fork: override the fork's cwd/git_root.

.PARAMETER LiveOnly
    When finding, only include sessions that currently hold a lock (i.e. appear
    to be running).

.PARAMETER All
    Find only: bypass the default relevance filters. By default a no-filter Find
    shows only non-empty sessions (>=1 user turn) for the current repo/folder,
    capped at the -Top most recently updated. -All lists every match instead.

.PARAMETER Top
    Find only: cap the default listing to the N most recently updated matches
    (default 30). Ignored when -All is set.

.PARAMETER LocalOnly
    Find only: skip cloud/agent sessions that were synced to disk but have no
    workspace.yaml. By default those cloud sessions are shown (Src = cloud).

.PARAMETER Sort
    Find only: listing order. Turns (default) = most prompts first (duration then
    recency as tiebreaks); Recent = most recently updated first; Duration =
    longest-lived first. The -Top cap is applied after ordering.

.PARAMETER Resume
    Find only: instead of listing, resume the top-ranked matching session with
    `copilot --resume=<id>`. Use -ResumeDirection to choose where it opens. Combine
    with filters/-Sort to control which session is picked (e.g. -Sort Recent
    -Resume resumes the most recently updated match).

.PARAMETER ResumeDirection
    Find only: where a -Resume session opens -- Right (default) or Left open a
    split pane on that side in the session's folder using the current pane manager
    (psmux, zellij, or Windows Terminal); InPlace runs it in the current terminal.
    With no pane manager available, Left/Right fall back to InPlace.

.PARAMETER Connect
    Sync only: attach to the live remote session with `copilot --connect=<id>`
    instead of the default `copilot --resume=<id>`.

.PARAMETER Launch
    For New/Fork: actually open the `copilot` session in a new terminal (a new
    tab in the current Windows Terminal window when inside WT, otherwise a new
    pwsh window) instead of only printing the command.

.PARAMETER Json
    Emit results as JSON instead of a formatted table / human text.

.OUTPUTS
    Find: session records (table or JSON).
    New/Fork/Sync: the resolved/created session id and the ready-to-run `copilot`
    command (machine-readable lines: SESSION_ID=..., SESSION_DIR=..., SESSION_CMD=...).
#>
[CmdletBinding()]
param(
    [ValidateSet('Find', 'New', 'Fork', 'Sync')]
    [string]$Action = 'Find',

    [string]$Path,
    [string]$Repository,
    [string]$Branch,
    [string]$Name,
    [string]$Session,
    [string]$NewName,
    [string]$WorkingDirectory,

    [switch]$LiveOnly,
    [switch]$Launch,
    [switch]$Json,

    # Find: bypass the default relevance filters (non-empty, current repo/folder,
    # top-N most recent) and list every session that matches the explicit filters.
    [switch]$All,

    # Find: cap the default listing to the N most recently updated matches.
    [int]$Top = 30,

    # Find: only list local CLI sessions (skip cloud/agent sessions synced to
    # disk that have no workspace.yaml). By default those cloud sessions ARE shown.
    [switch]$LocalOnly,

    # Find: order of the listing. Turns (default) = most prompts first, with
    # session duration as a tiebreak; Recent = most recently updated first;
    # Duration = longest-lived first.
    [ValidateSet('Turns', 'Recent', 'Duration')]
    [string]$Sort = 'Turns',

    # Find: pick the top session from the (filtered, sorted) list and resume it
    # with `copilot --resume=<id>`. Use -ResumeDirection to choose where it opens.
    [switch]$Resume,

    # Find: where a -Resume session opens. Right (default) / Left open a split pane
    # on that side in the session's folder using the current pane manager (psmux,
    # zellij, or Windows Terminal); InPlace runs it in the current terminal. With no
    # pane manager available, Left/Right fall back to InPlace. Right is the default
    # because every supported pane manager can place a pane on the right.
    [ValidateSet('Left', 'Right', 'InPlace')]
    [string]$ResumeDirection = 'Right',

    # Sync: use `copilot --connect=<id>` (attach to the live remote session)
    # instead of the default `copilot --resume=<id>` (resume/materialize locally).
    [switch]$Connect
)

$ErrorActionPreference = 'Stop'

# Shared terminal/pane helpers (Resolve-WtExe, Open-CommandPane). This is a
# vendored copy kept in sync from shared\Terminal-Panes.ps1 via
# tools\Sync-SharedScripts.ps1 so the plugin stays self-contained.
. (Join-Path $PSScriptRoot 'Terminal-Panes.ps1')

$StateRoot = Join-Path $env:USERPROFILE '.copilot\session-state'

# --- Metadata/turns cache -----------------------------------------------------
# Building a record for every session (there can be hundreds) means reading each
# workspace.yaml and, for turn counts, each (potentially huge) events.jsonl. That
# work is redundant run-to-run because those files rarely change. Cache the
# derived values in a single JSON file, keyed by the session directory, and reuse
# an entry while the underlying file's size/mtime is unchanged. Everything here
# degrades gracefully to a cold recompute if the cache is missing or corrupt.
$script:CacheFile = Join-Path $StateRoot '.find-cache.json'
$script:Cache = @{}
$script:CacheDirty = $false

function Import-FindCache {
    $script:Cache = @{}
    if (Test-Path $script:CacheFile) {
        try {
            $obj = Get-Content $script:CacheFile -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) {
                $h = @{}
                foreach ($pp in $p.Value.PSObject.Properties) { $h[$pp.Name] = $pp.Value }
                $script:Cache[$p.Name] = $h
            }
        } catch { $script:Cache = @{} }
    }
}

function Get-CacheEntry([string]$key) {
    $e = $script:Cache[$key]
    if ($e -isnot [hashtable]) {
        $h = @{}
        if ($e) { foreach ($p in $e.PSObject.Properties) { $h[$p.Name] = $p.Value } }
        $script:Cache[$key] = $h
        $e = $h
    }
    return $e
}

function Save-FindCache {
    if (-not $script:CacheDirty) { return }
    try {
        # Drop entries for sessions that no longer exist so the file can't grow
        # without bound.
        foreach ($k in @($script:Cache.Keys)) {
            if (-not (Test-Path -LiteralPath $k -PathType Container)) { $script:Cache.Remove($k) }
        }
        ($script:Cache | ConvertTo-Json -Depth 6 -Compress) |
            Set-Content -LiteralPath $script:CacheFile -Encoding UTF8 -ErrorAction Stop
    } catch {}
}

function Set-LiveInfo($records) {
    # Populate Live/LivePid on the given records on demand. This is deferred out of
    # the bulk metadata scan because probing every session's lock file (and the
    # owning process) for hundreds of sessions is expensive and only the handful
    # we actually display/act on need it.
    foreach ($r in @($records)) {
        if ($r.PSObject.Properties['LiveResolved'] -and $r.LiveResolved) { continue }
        $livePid = Get-LiveLockPid $r.Dir
        $r.Live = [bool]$livePid
        $r.LivePid = $livePid
        $r | Add-Member -NotePropertyName LiveResolved -NotePropertyValue $true -Force
    }
    return $records
}

function Get-CopilotExe {
    $c = Get-Command copilot -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return 'copilot'
}

function Get-LiveLockPid([string]$dir) {
    # A session marks itself in-use with an 'inuse.<pid>.lock' file containing the
    # owning process id. These files linger after a crash/unclean exit, so their
    # mere presence does NOT mean the session is live -- verify the pid is running.
    # Returns the live owner pid, or $null when there's no running owner.
    foreach ($lk in @(Get-ChildItem $dir -Filter 'inuse.*.lock' -ErrorAction SilentlyContinue)) {
        $procId = 0
        $txt = (Get-Content $lk.FullName -Raw -ErrorAction SilentlyContinue)
        if ($txt -and [int]::TryParse($txt.Trim(), [ref]$procId) -and $procId -gt 0) {
            if (Get-Process -Id $procId -ErrorAction SilentlyContinue) { return $procId }
        }
    }
    return $null
}

function Show-ProcessWindow([int]$ProcessId) {
    # Bring the terminal window hosting a given process to the foreground. The live
    # copilot process is usually a console app with no window of its own (it's hosted
    # inside a terminal), so walk up the parent chain until we find an ancestor that
    # owns a top-level window (pwsh/conhost, or WindowsTerminal). Returns $true if a
    # window was activated.
    if (-not ('CopilotSession.Win32Window' -as [type])) {
        Add-Type -Namespace CopilotSession -Name Win32Window -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsIconic(System.IntPtr hWnd);
'@ -ErrorAction SilentlyContinue
    }
    $seen = @{}
    $curId = $ProcessId
    for ($i = 0; $i -lt 8 -and $curId -and -not $seen.ContainsKey($curId); $i++) {
        $seen[$curId] = $true
        $proc = Get-Process -Id $curId -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -ne [System.IntPtr]::Zero) {
            $h = $proc.MainWindowHandle
            if ([CopilotSession.Win32Window]::IsIconic($h)) { [CopilotSession.Win32Window]::ShowWindow($h, 9) | Out-Null } # SW_RESTORE
            [CopilotSession.Win32Window]::SetForegroundWindow($h) | Out-Null
            return $true
        }
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $curId" -ErrorAction SilentlyContinue
        $curId = if ($parent) { [int]$parent.ParentProcessId } else { 0 }
    }
    return $false
}

function ConvertFrom-WorkspaceYaml([string]$text) {
    # workspace.yaml is a flat "key: value" map -- parse just what we need.
    $map = @{}
    foreach ($line in ($text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*([A-Za-z0-9_]+)\s*:\s*(.*?)\s*$')
        if ($m.Success) {
            $v = $m.Groups[2].Value.Trim()
            if ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[-1] -eq '"') { $v = $v.Substring(1, $v.Length - 2) }
            $map[$m.Groups[1].Value] = $v
        }
    }
    return $map
}

function New-CloudSessionRecord {
    # Build a session record from a folder that has NO workspace.yaml -- these are
    # cloud/agent sessions (started or steered from GitHub web/mobile) that were
    # synced to disk. Metadata is recovered from events.jsonl: the first line is a
    # session.start (id, producer, startTime); cwd shows up in a later event.
    # Cached by the events.jsonl size+mtime so we only re-parse the head when the
    # file actually changes. Live info is left unresolved (see Set-LiveInfo).
    param([Parameter(Mandatory)]$Dir)
    $evi = Get-Item (Join-Path $Dir.FullName 'events.jsonl') -ErrorAction SilentlyContinue
    if (-not $evi) { return $null }
    $ev = $evi.FullName
    $ent = Get-CacheEntry $Dir.FullName
    if ($ent.evTicks -eq $evi.LastWriteTimeUtc.Ticks -and $ent.evSize -eq $evi.Length -and $ent.cloudRec) {
        # Rebuild a fresh object so later live-info mutation can't leak back into
        # the cached record.
        $c = [ordered]@{}
        foreach ($p in ([pscustomobject]$ent.cloudRec).PSObject.Properties) { $c[$p.Name] = $p.Value }
        $c.Live = $false
        $c.LivePid = $null
        return [pscustomobject]$c
    }
    $head = Get-Content $ev -TotalCount 40 -ErrorAction SilentlyContinue
    if (-not $head) { return $null }
    $start = try { $head[0] | ConvertFrom-Json } catch { $null }
    if (-not $start -or $start.type -ne 'session.start') { return $null }
    $cwd = ''
    $m = [regex]::Match(($head -join "`n"), '"cwd"\s*:\s*"([^"]+)"')
    if ($m.Success) { $cwd = $m.Groups[1].Value -replace '/', '\' }
    $rec = [ordered]@{
        Id           = if ($start.data.sessionId) { $start.data.sessionId } else { $Dir.Name }
        Name         = ''
        Repository   = ''
        Branch       = ''
        Cwd          = $cwd
        GitRoot      = ''
        Created      = if ($start.data.startTime) { ([datetimeoffset]$start.data.startTime).ToString('o') } else { '' }
        Updated      = $Dir.LastWriteTimeUtc.ToString('o')
        SizeKB       = [math]::Round($evi.Length / 1KB)
        Live         = $false
        LivePid      = $null
        Origin       = 'cloud'
        Dir          = $Dir.FullName
    }
    $ent.evTicks = $evi.LastWriteTimeUtc.Ticks
    $ent.evSize = $evi.Length
    $ent.cloudRec = $rec
    $script:CacheDirty = $true
    return [pscustomobject]$rec
}

function Get-Sessions {
    param([switch]$IncludeCloud)
    if (-not (Test-Path $StateRoot)) { return @() }
    $sessions = foreach ($d in Get-ChildItem $StateRoot -Directory -ErrorAction SilentlyContinue) {
        $wfi = Get-Item (Join-Path $d.FullName 'workspace.yaml') -ErrorAction SilentlyContinue
        if (-not $wfi) {
            if ($IncludeCloud) {
                $rec = New-CloudSessionRecord -Dir $d
                if ($rec) { $rec }
            }
            continue
        }
        $ev = Join-Path $d.FullName 'events.jsonl'
        $size = if (Test-Path $ev) { (Get-Item $ev).Length } else { 0 }
        $ent = Get-CacheEntry $d.FullName
        if ($ent.wsTicks -eq $wfi.LastWriteTimeUtc.Ticks -and $ent.rec) {
            $rec = [ordered]@{}
            foreach ($p in ([pscustomobject]$ent.rec).PSObject.Properties) { $rec[$p.Name] = $p.Value }
            $rec.SizeKB = [math]::Round($size / 1KB)   # size can change without workspace.yaml changing
        } else {
            $ws = ConvertFrom-WorkspaceYaml (Get-Content $wfi.FullName -Raw)
            $rec = [ordered]@{
                Id         = if ($ws.id) { $ws.id } else { $d.Name }
                Name       = $ws.name
                Repository = $ws.repository
                Branch     = $ws.branch
                Cwd        = $ws.cwd
                GitRoot    = $ws.git_root
                Created    = $ws.created_at
                Updated    = $ws.updated_at
                SizeKB     = [math]::Round($size / 1KB)
                Origin     = 'local'
                Dir        = $d.FullName
            }
            $ent.wsTicks = $wfi.LastWriteTimeUtc.Ticks
            $ent.rec = $rec
            $script:CacheDirty = $true
        }
        # Live info is resolved lazily for just the sessions we display/act on.
        $rec.Live = $false
        $rec.LivePid = $null
        [pscustomobject]$rec
    }
    return @($sessions)
}

function Get-RepoSlug([string]$value) {
    # Reduce a git URL (https/ssh) to an owner/name path for matching; leave a
    # plain slug untouched.
    if (-not $value) { return $value }
    $v = $value.Trim()
    $v = $v -replace '\.git$', ''
    if ($v -match '^(?:https?://|git@|ssh://)') {
        $v = $v -replace '^git@[^:]+:', ''          # git@host:owner/repo
        $v = $v -replace '^ssh://[^/]+/', ''         # ssh://host/owner/repo
        $v = $v -replace '^https?://[^/]+/', ''      # https://host/owner/repo
    }
    return $v.Trim('/')
}

function Get-SessionTurns([string]$dir) {
    # Count user prompts in a session by tallying "user.message" events. Uses a
    # raw regex over events.jsonl (one JSON object per line) so it stays fast even
    # for large histories -- no per-line JSON parsing. Cached by the file's
    # size+mtime so large, unchanged histories aren't re-read on every run.
    $evi = Get-Item (Join-Path $dir 'events.jsonl') -ErrorAction SilentlyContinue
    if (-not $evi) { return 0 }
    $ent = Get-CacheEntry $dir
    if ($ent.turnsSize -eq $evi.Length -and $ent.turnsTicks -eq $evi.LastWriteTimeUtc.Ticks -and $null -ne $ent.turns) {
        return $ent.turns
    }
    try {
        # Stream line-by-line and substring-match instead of ReadAllText + regex:
        # events.jsonl is one JSON object per line, so each user.message is its own
        # line. This avoids allocating a multi-MB string and a big MatchCollection
        # for large histories.
        $n = 0
        $sr = New-Object IO.StreamReader($evi.FullName)
        try {
            while ($null -ne ($line = $sr.ReadLine())) {
                if ($line.Contains('"type":"user.message"')) { $n++ }
            }
        } finally { $sr.Dispose() }
    } catch { return 0 }
    $ent.turnsSize = $evi.Length
    $ent.turnsTicks = $evi.LastWriteTimeUtc.Ticks
    $ent.turns = $n
    $script:CacheDirty = $true
    return $n
}

function Format-Duration([string]$created, [string]$updated) {
    # Compact span between created_at and updated_at (e.g. 45s, 3m, 2h5m, 1d4h).
    if (-not $created -or -not $updated) { return '' }
    try {
        $c = [datetimeoffset]::Parse($created, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $u = [datetimeoffset]::Parse($updated, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return '' }
    $s = $u - $c
    if ($s.TotalSeconds -lt 0) { return '' }
    if ($s.TotalDays -ge 1) { return ('{0}d{1}h' -f [int]$s.Days, $s.Hours) }
    if ($s.TotalHours -ge 1) { return ('{0}h{1}m' -f [int]$s.Hours, $s.Minutes) }
    if ($s.TotalMinutes -ge 1) { return ('{0}m' -f [int]$s.Minutes) }
    return ('{0}s' -f [int]$s.Seconds)
}

function Get-DurationSeconds([string]$created, [string]$updated) {
    # Numeric lifespan in seconds (for sorting); 0 when unknown/invalid.
    if (-not $created -or -not $updated) { return 0 }
    try {
        $c = [datetimeoffset]::Parse($created, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $u = [datetimeoffset]::Parse($updated, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return 0 }
    $s = ($u - $c).TotalSeconds
    if ($s -lt 0) { 0 } else { $s }
}

function Get-CurrentRepoSlug {
    # owner/name slug for the git repo containing the current directory, or $null.
    try {
        $url = git -C (Get-Location).Path remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $url) { return (Get-RepoSlug $url).ToLowerInvariant() }
    } catch {}
    return $null
}

function Select-Sessions {
    param([switch]$IncludeCloud)
    $all = Get-Sessions -IncludeCloud:$IncludeCloud
    $result = $all
    if ($LiveOnly) { $result = Set-LiveInfo $result | Where-Object { $_.Live } }
    if ($Path) {
        $p = $Path
        if ($p -eq '.' -or (Test-Path $p)) { try { $p = (Resolve-Path -LiteralPath $p).Path } catch {} }
        $p = $p.TrimEnd('\').ToLowerInvariant()
        $result = $result | Where-Object {
            ($_.Cwd -and $_.Cwd.TrimEnd('\').ToLowerInvariant().Contains($p)) -or
            ($_.GitRoot -and $_.GitRoot.TrimEnd('\').ToLowerInvariant().Contains($p))
        }
    }
    if ($Repository) {
        $r = (Get-RepoSlug $Repository).ToLowerInvariant()
        $result = $result | Where-Object { $_.Repository -and $_.Repository.ToLowerInvariant().Contains($r) }
    }
    if ($Branch) {
        $b = $Branch.ToLowerInvariant()
        $result = $result | Where-Object { $_.Branch -and $_.Branch.ToLowerInvariant().Contains($b) }
    }
    if ($Name) {
        $nm = $Name.ToLowerInvariant()
        $result = $result | Where-Object { $_.Name -and $_.Name.ToLowerInvariant().Contains($nm) }
    }
    return @($result | Sort-Object { $_.Updated } -Descending)
}

function Resolve-OneSession {
    # For Fork: pick exactly one session from -Session or from the filters.
    if ($Session) {
        $all = Get-Sessions
        $hit = $all | Where-Object { $_.Id -eq $Session }
        if (-not $hit) { $hit = $all | Where-Object { $_.Id -like "$Session*" -and $Session.Length -ge 7 } }
        if (-not $hit) { $hit = $all | Where-Object { $_.Name -and $_.Name.ToLowerInvariant() -eq $Session.ToLowerInvariant() } }
        $hit = @($hit)
        if ($hit.Count -eq 0) { throw "No session matches -Session '$Session' (id, 7+ char prefix, or exact name)." }
        if ($hit.Count -gt 1) { throw "Ambiguous -Session '$Session' matches $($hit.Count) sessions: $(( $hit | ForEach-Object { $_.Id }) -join ', ')." }
        return $hit[0]
    }
    $hit = Select-Sessions
    if ($hit.Count -eq 0) { throw 'No session matches the given filters. Refine -Path / -Repository / -Branch / -Name, or pass -Session <id>.' }
    if ($hit.Count -gt 1) {
        $lines = $hit | Select-Object -First 10 | ForEach-Object { "  $($_.Id.Substring(0,8))  $($_.Name)  [$($_.Branch)]  $($_.Cwd)" }
        throw "Filters match $($hit.Count) sessions; narrow them or pass -Session <id>:`n$($lines -join "`n")"
    }
    return $hit[0]
}

function Set-ForkIdentity {
    param(
        [Parameter(Mandatory)][string]$ForkDir,
        [Parameter(Mandatory)][string]$SeedId,
        [Parameter(Mandatory)][string]$ForkId,
        [string]$NewCwd,
        [string]$NewBranch,
        [string]$NewSessionName
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # --- workspace.yaml: new id (+ optional cwd/branch/name), drop remote ids ---
    $wsPath = Join-Path $ForkDir 'workspace.yaml'
    if (Test-Path $wsPath) {
        $nowIso = [DateTime]::UtcNow.ToString('o')
        $new = foreach ($line in [IO.File]::ReadAllLines($wsPath)) {
            switch -regex ($line) {
                '^(mc_task_id|mc_session_id|mc_last_event_id)\s*:' { continue }
                '^id:\s'               { "id: $ForkId"; continue }
                '^cwd:\s'              { if ($NewCwd) { "cwd: $NewCwd" } else { $line }; continue }
                '^git_root:\s'         { if ($NewCwd) { "git_root: $NewCwd" } else { $line }; continue }
                '^branch:\s'           { if ($NewBranch) { "branch: $NewBranch" } else { $line }; continue }
                '^name:\s'             { if ($NewSessionName) { "name: $NewSessionName" } else { $line }; continue }
                '^user_named:\s'       { if ($NewSessionName) { 'user_named: true' } else { $line }; continue }
                '^remote_steerable:\s' { 'remote_steerable: false'; continue }
                '^updated_at:\s'       { "updated_at: $nowIso"; continue }
                default                { $line }
            }
        }
        [IO.File]::WriteAllText($wsPath, ($new -join "`n") + "`n", $utf8NoBom)
    }

    # --- events.jsonl: replace every embedded seed id with the fork id ---
    $evPath = Join-Path $ForkDir 'events.jsonl'
    if (Test-Path $evPath) {
        $tmpPath = "$evPath.fork.tmp"
        $reader = New-Object IO.StreamReader($evPath, $utf8NoBom)
        $writer = New-Object IO.StreamWriter($tmpPath, $false, $utf8NoBom)
        $writer.NewLine = "`n"
        try {
            while ($null -ne ($l = $reader.ReadLine())) { $writer.WriteLine($l.Replace($SeedId, $ForkId)) }
        } finally { $reader.Dispose(); $writer.Dispose() }
        Move-Item $tmpPath $evPath -Force
    }

    # --- session.db: repoint inbox entries (best-effort; needs python) ---
    $dbPath = Join-Path $ForkDir 'session.db'
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ((Test-Path $dbPath) -and $py) {
        $code = "import sqlite3,sys`n" +
                "c=sqlite3.connect(sys.argv[1]);cur=c.cursor()`n" +
                "try:`n cur.execute('UPDATE inbox_entries SET recipient_session_id=? WHERE recipient_session_id=?',(sys.argv[3],sys.argv[2]))`nexcept Exception: pass`n" +
                "c.commit();c.close()"
        try { & $py.Source -c $code $dbPath $SeedId $ForkId 2>$null | Out-Null } catch {}
    }
}

function Open-CopilotViewer([string[]]$CopilotArgs) {
    # Open an interactive copilot in a new terminal. A WT tab in the current
    # window when inside Windows Terminal, else a new pwsh window that runs
    # copilot. Resolve-WtExe picks the wt.exe for the edition actually hosting us
    # (stable vs Preview) so '-w 0' targets the current window.
    $exe = Get-CopilotExe
    $wtExe = Resolve-WtExe
    $hasWt = ($wtExe -ne 'wt.exe') -or [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
    if ($env:WT_SESSION -and $hasWt) {
        $wtArgs = @('-w', '0', 'new-tab', '--title', 'copilot', $exe) + $CopilotArgs
        Start-Process -FilePath $wtExe -ArgumentList $wtArgs | Out-Null
    } else {
        $inner = "& '$($exe -replace "'", "''")'"
        foreach ($a in $CopilotArgs) { $inner += " '$($a -replace "'", "''")'" }
        Start-Process -FilePath 'pwsh' -WindowStyle Normal `
            -ArgumentList @('-NoProfile', '-NoExit', '-Command', $inner) | Out-Null
    }
}

function Open-CopilotPane {
    # Open `copilot <CopilotArgs>` in a split pane beside the current one, in the
    # given working directory, using whichever pane manager we're inside. Thin
    # wrapper over the shared Open-CommandPane (psmux/zellij/Windows Terminal),
    # which also resolves the correct wt.exe edition and takes psmux's fast
    # profile path. Returns 'psmux'/'zellij'/'wt', or $null when no pane manager
    # is available so the caller can fall back to running in place.
    param(
        [string[]]$CopilotArgs,
        [string]$Cwd,
        [ValidateSet('Left', 'Right')][string]$Side = 'Right'
    )
    $exe = Get-CopilotExe
    return Open-CommandPane -Command $exe -Arguments $CopilotArgs -Cwd $Cwd -Side $Side
}

# ---------------------------------------------------------------------------
Import-FindCache
try {
    switch ($Action) {

    'Find' {
        $hits = Select-Sessions -IncludeCloud:(-not $LocalOnly)

        # Default view (unless -All): limit to the current repo/folder when we're
        # inside one and no explicit -Path/-Repository was given. Sorting by usage
        # means we need turn counts up front, so we compute metrics for every
        # candidate that survives this cheap filter.
        if (-not $All -and -not $Path -and -not $Repository) {
            $curPath = (Get-Location).Path.TrimEnd('\').ToLowerInvariant()
            $curSlug = Get-CurrentRepoSlug
            if ($curSlug -or $curPath) {
                $hits = @($hits | Where-Object {
                    ($curSlug -and $_.Repository -and $_.Repository.ToLowerInvariant().Contains($curSlug)) -or
                    ($_.Cwd -and $_.Cwd.TrimEnd('\').ToLowerInvariant().Contains($curPath)) -or
                    ($_.GitRoot -and $_.GitRoot.TrimEnd('\').ToLowerInvariant().Contains($curPath))
                })
            }
        }

        # Compute usage metrics (turns + duration) for each candidate.
        foreach ($h in $hits) {
            $h | Add-Member -NotePropertyName Turns -NotePropertyValue (Get-SessionTurns $h.Dir) -Force
            $h | Add-Member -NotePropertyName Duration -NotePropertyValue (Format-Duration $h.Created $h.Updated) -Force
            $h | Add-Member -NotePropertyName DurationSeconds -NotePropertyValue (Get-DurationSeconds $h.Created $h.Updated) -Force
        }

        # Default view hides empty sessions (no user turns).
        if (-not $All) { $hits = @($hits | Where-Object { $_.Turns -ge 1 }) }

        # Order by the chosen key (all descending): Turns (default) puts the most
        # active sessions first with duration then recency as tiebreaks; Duration
        # ranks longest-lived first; Recent ranks most recently updated first.
        $hits = switch ($Sort) {
            'Recent'   { @($hits | Sort-Object -Property Updated -Descending) }
            'Duration' { @($hits | Sort-Object -Property DurationSeconds, Updated -Descending) }
            default    { @($hits | Sort-Object -Property Turns, DurationSeconds, Updated -Descending) }
        }

        # Cap the default view to the top -Top after ordering.
        if (-not $All -and $hits.Count -gt $Top) { $hits = @($hits | Select-Object -First $Top) }

        # Resolve live/PID info now -- only for the sessions we're about to show or
        # resume, rather than every session on disk.
        $hits = @(Set-LiveInfo $hits)

        # -Resume: jump straight into the top-ranked session instead of listing.
        if ($Resume) {
            if (-not $hits -or $hits.Count -eq 0) {
                Write-Host 'No session to resume for the current filters.' -ForegroundColor Yellow
                return
            }
            $target = $hits[0]
            $label = if ($target.Name) { $target.Name } else { "$($target.Origin) session" }
            $exe = Get-CopilotExe
            if ($target.Live) {
                Write-Host "Session $($target.Id) ($label) is already running (PID $($target.LivePid))." -ForegroundColor Yellow
                if (Show-ProcessWindow -ProcessId $target.LivePid) {
                    Write-Host 'Switched to its existing terminal window (copilot refuses two live instances of one session).' -ForegroundColor Green
                } else {
                    Write-Host "Couldn't locate its window. Switch to it manually, or use Fork-CopilotSession to branch a copy." -ForegroundColor Yellow
                }
                return
            }
            Write-Host "Resuming $($target.Id) ($label)..." -ForegroundColor Cyan
            $resumeArg = "--resume=$($target.Id)"
            if ($ResumeDirection -eq 'InPlace') {
                & $exe $resumeArg
            } else {
                $paneHost = Open-CopilotPane -CopilotArgs @($resumeArg) -Cwd $target.Cwd -Side $ResumeDirection
                if ($paneHost) {
                    Write-Host "Opened it in a $($ResumeDirection.ToLower()) pane ($paneHost)." -ForegroundColor Green
                } else {
                    Write-Host 'No pane manager (psmux/zellij/Windows Terminal) detected; resuming in place.' -ForegroundColor DarkGray
                    & $exe $resumeArg
                }
            }
            return
        }

        if ($Json) {
            $hits | Select-Object Id, Name, Repository, Branch, Cwd, GitRoot, Created, Updated, Turns, Duration, SizeKB, Live, LivePid, Origin, Dir |
                ConvertTo-Json -Depth 4
        } else {
            if (-not $hits -or $hits.Count -eq 0) {
                Write-Host 'No matching Copilot sessions found.' -ForegroundColor Yellow
                if (-not $All) {
                    Write-Host 'Default view shows non-empty sessions for the current repo/folder. Use -All to list everything.' -ForegroundColor DarkGray
                }
            } else {
                $hits | Select-Object `
                    @{n = 'Id'; e = { $_.Id } },
                    @{n = 'Src'; e = { $_.Origin } },
                    @{n = 'Branch'; e = { $_.Branch } },
                    @{n = 'Turns'; e = { $_.Turns } },
                    @{n = 'Dur'; e = { $_.Duration } },
                    @{n = 'PID'; e = { if ($_.Live) { $_.LivePid } else { '' } } },
                    @{n = 'Folder'; e = { $_.Cwd } },
                    @{n = 'Name'; e = { if ($_.Name -and $_.Name.Length -gt 40) { $_.Name.Substring(0, 39) + '…' } else { $_.Name } } } |
                    Format-Table -AutoSize
                $cloud = @($hits | Where-Object { $_.Origin -eq 'cloud' }).Count
                $order = switch ($Sort) { 'Recent' { 'most recent' } 'Duration' { 'longest-lived' } default { 'most turns' } }
                $suffix = if (-not $All) { " (non-empty, current repo/folder, top $Top by $order)" } else { " (by $order)" }
                $csuffix = if ($cloud -gt 0) { " $cloud from cloud." } else { '' }
                Write-Host "$($hits.Count) session(s)$suffix.$csuffix Resume one with:  copilot --resume=<id>" -ForegroundColor DarkGray
            }
        }
    }

    'New' {
        $exe = Get-CopilotExe
        $newArgs = @()
        if ($NewName) { $newArgs += @('--name', $NewName) }
        $dir = if ($WorkingDirectory) { $WorkingDirectory } elseif ($Path) { $Path } else { $null }
        if ($dir) {
            $dir = (Resolve-Path -LiteralPath $dir).Path
            $newArgs += @('-C', $dir)
        }
        $cmd = "$exe " + (($newArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')
        Write-Host "SESSION_CMD=$($cmd.TrimEnd())"
        if ($Launch) {
            Open-CopilotViewer $newArgs
            Write-Host 'Launched a new Copilot session in a separate terminal.' -ForegroundColor Green
        } else {
            Write-Host 'Run the command above to start the session (add -Launch to open it in a new terminal).' -ForegroundColor DarkGray
        }
    }

    'Fork' {
        $seed = Resolve-OneSession
        $forkId = [guid]::NewGuid().ToString()
        $forkDir = Join-Path $StateRoot $forkId
        Write-Host "Forking session $($seed.Id) ($($seed.Name)) -> $forkId ..." -ForegroundColor Cyan

        # Copy the seed folder, then drop volatile lock/temp files.
        Copy-Item -LiteralPath $seed.Dir -Destination $forkDir -Recurse -Force
        Get-ChildItem $forkDir -Filter '*.lock' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem $forkDir -Filter '*.fork.tmp' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

        $newCwd = if ($WorkingDirectory) { (Resolve-Path -LiteralPath $WorkingDirectory).Path } else { $null }
        Set-ForkIdentity -ForkDir $forkDir -SeedId $seed.Id -ForkId $forkId `
            -NewCwd $newCwd -NewBranch $Branch -NewSessionName $NewName

        $exe = Get-CopilotExe
        $resumeArgs = @("--resume=$forkId")
        Write-Host ''
        Write-Host "SESSION_ID=$forkId"
        Write-Host "SESSION_DIR=$forkDir"
        Write-Host "SESSION_CMD=$exe --resume=$forkId"
        if ($Launch) {
            Open-CopilotViewer $resumeArgs
            Write-Host 'Opened the forked session in a separate terminal.' -ForegroundColor Green
        } else {
            Write-Host "Resume the fork with:  $exe --resume=$forkId" -ForegroundColor DarkGray
        }
    }

    'Sync' {
        # Pull a cloud/remote session or task down for local use. There is no
        # "download only" command -- attaching/resuming by id is what materializes
        # it locally. Accept the id via -Session (a cloud session id, task id, id
        # prefix, or name). -Connect attaches to the live remote session
        # (`--connect`); otherwise we resume it (`--resume`).
        if (-not $Session) {
            throw "Sync needs -Session <cloud session id | task id | id prefix | name>. Get ids from GitHub web/mobile, the cloud store, or another machine."
        }
        $exe = Get-CopilotExe
        $flag = if ($Connect) { "--connect=$Session" } else { "--resume=$Session" }
        $syncArgs = @($flag)
        if ($WorkingDirectory) { $syncArgs += @('-C', (Resolve-Path -LiteralPath $WorkingDirectory).Path) }

        $local = @(Get-Sessions | Where-Object { $_.Id -eq $Session -or ($Session.Length -ge 7 -and $_.Id -like "$Session*") })
        if ($local.Count -gt 0) {
            Write-Host "Note: a local session already matches '$Session' ($($local[0].Id)); this will resume it in place." -ForegroundColor DarkGray
        }

        Write-Host "SESSION_ID=$Session"
        Write-Host "SESSION_CMD=$exe $flag"
        if ($Launch) {
            Open-CopilotViewer $syncArgs
            Write-Host "Opened '$Session' in a separate terminal; it will be materialized locally on connect." -ForegroundColor Green
        } else {
            Write-Host "Run the command above to pull it down locally (add -Launch to open it in a new terminal; -Connect to attach to the live remote session)." -ForegroundColor DarkGray
        }
    }
}
} finally {
    Save-FindCache
}
