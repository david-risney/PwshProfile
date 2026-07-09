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
      * New    -- start a fresh session (prints, or with -Launch opens, the
                  `copilot` command; supports -Name, -WorkingDirectory).
      * Fork   -- clone an existing session into a NEW, fully independent session
                  (new id, remote-attach ids stripped) so you can branch off its
                  history without disturbing the original.

    On "official fork": there is NO dedicated `copilot fork` command. The CLI's
    `--resume`, `--continue`, `--connect`, and `--session-id` flags only *resume
    or attach to* an existing session -- resuming the same id keeps writing to
    the same history. Forking therefore means duplicating the session folder and
    rewriting its identifiers, which is what -Action Fork does here.

.PARAMETER Action
    Find (default), New, or Fork.

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
    Explicit session selector for -Action Fork: a full id, an id prefix (7+ hex
    chars), or an exact session name.

.PARAMETER NewName
    Name to assign to the new/forked session.

.PARAMETER WorkingDirectory
    For -Action New: directory to start the session in (default: current dir).
    For -Action Fork: override the fork's cwd/git_root.

.PARAMETER LiveOnly
    When finding, only include sessions that currently hold a lock (i.e. appear
    to be running).

.PARAMETER Launch
    For New/Fork: actually open the `copilot` session in a new terminal (a new
    tab in the current Windows Terminal window when inside WT, otherwise a new
    pwsh window) instead of only printing the command.

.PARAMETER Json
    Emit results as JSON instead of a formatted table / human text.

.OUTPUTS
    Find: session records (table or JSON).
    New/Fork: the resolved/created session id and the ready-to-run `copilot`
    command (machine-readable lines: SESSION_ID=..., SESSION_DIR=..., SESSION_CMD=...).
#>
[CmdletBinding()]
param(
    [ValidateSet('Find', 'New', 'Fork')]
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
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$StateRoot = Join-Path $env:USERPROFILE '.copilot\session-state'

function Get-CopilotExe {
    $c = Get-Command copilot -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return 'copilot'
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

function Get-Sessions {
    if (-not (Test-Path $StateRoot)) { return @() }
    $sessions = foreach ($d in Get-ChildItem $StateRoot -Directory -ErrorAction SilentlyContinue) {
        $wf = Join-Path $d.FullName 'workspace.yaml'
        if (-not (Test-Path $wf)) { continue }
        $ws = ConvertFrom-WorkspaceYaml (Get-Content $wf -Raw)
        $ev = Join-Path $d.FullName 'events.jsonl'
        $size = if (Test-Path $ev) { (Get-Item $ev).Length } else { 0 }
        $live = @(Get-ChildItem $d.FullName -Filter '*.lock' -ErrorAction SilentlyContinue).Count -gt 0
        [pscustomobject]@{
            Id         = if ($ws.id) { $ws.id } else { $d.Name }
            Name       = $ws.name
            Repository = $ws.repository
            Branch     = $ws.branch
            Cwd        = $ws.cwd
            GitRoot    = $ws.git_root
            Created    = $ws.created_at
            Updated    = $ws.updated_at
            SizeKB     = [math]::Round($size / 1KB)
            Live       = $live
            Dir        = $d.FullName
        }
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

function Select-Sessions {
    $all = Get-Sessions
    $result = $all
    if ($LiveOnly) { $result = $result | Where-Object { $_.Live } }
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
    # copilot. NOTE: wt.exe is a Store app-execution-alias, launch it BY NAME.
    $exe = Get-CopilotExe
    $hasWt = [bool](Get-Command wt -ErrorAction SilentlyContinue)
    if ($env:WT_SESSION -and $hasWt) {
        $wtArgs = @('-w', '0', 'new-tab', '--title', 'copilot', $exe) + $CopilotArgs
        Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs | Out-Null
    } else {
        $inner = "& '$($exe -replace "'", "''")'"
        foreach ($a in $CopilotArgs) { $inner += " '$($a -replace "'", "''")'" }
        Start-Process -FilePath 'pwsh' -WindowStyle Normal `
            -ArgumentList @('-NoProfile', '-NoExit', '-Command', $inner) | Out-Null
    }
}

# ---------------------------------------------------------------------------
switch ($Action) {

    'Find' {
        $hits = Select-Sessions
        if ($Json) {
            $hits | Select-Object Id, Name, Repository, Branch, Cwd, GitRoot, Created, Updated, SizeKB, Live, Dir |
                ConvertTo-Json -Depth 4
        } else {
            if (-not $hits -or $hits.Count -eq 0) {
                Write-Host 'No matching Copilot sessions found.' -ForegroundColor Yellow
            } else {
                $hits | Select-Object `
                    @{n = 'Id'; e = { $_.Id.Substring(0, 8) } },
                    @{n = 'Name'; e = { $_.Name } },
                    @{n = 'Branch'; e = { $_.Branch } },
                    @{n = 'Repository'; e = { $_.Repository } },
                    @{n = 'Updated'; e = { $_.Updated } },
                    @{n = 'KB'; e = { $_.SizeKB } },
                    @{n = 'Live'; e = { if ($_.Live) { '*' } else { '' } } },
                    @{n = 'Cwd'; e = { $_.Cwd } } |
                    Format-Table -AutoSize
                Write-Host "$($hits.Count) session(s). Resume one with:  copilot --resume=<id>" -ForegroundColor DarkGray
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
}
