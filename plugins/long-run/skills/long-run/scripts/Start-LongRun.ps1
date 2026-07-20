<#
.SYNOPSIS
    Start one or more long-running commands inside a detached terminal-multiplexer
    session (psmux, or zellij as a fallback) and open a live viewer. Multiple
    commands each run in their own pane within a single tab.

.DESCRIPTION
    Each command runs in a multiplexer pane so the job is decoupled from the
    Copilot CLI session: the multiplexer server owns the pane, so closing the
    viewer only DETACHES -- the job keeps running and can be re-attached later.
    The job therefore survives interrupts, tool-call timeouts, and closed
    viewers.

    Pass a single -Command to run one job, or several to run them side by side --
    each command gets its own pane (tiled) in the same tab, with its own
    status/log files so each can be tracked independently.

    Multiplexer selection (per requirements):
      * Prefer psmux.
      * Use zellij only if zellij is installed and psmux is not.
      * If neither is installed, install psmux (winget: marlocarlo.psmux).
      * EXCEPTION: if this script is already running inside a psmux or zellij
        session, that multiplexer is used so the job opens as a new tab in the
        CURRENT session.

    Viewer selection (per requirements):
      * Inside a psmux/zellij session  -> new tab in the current session.
      * Else inside Windows Terminal    -> new tab in the current WT window.
      * Else                            -> a new pwsh window.

    This script NEVER runs an attaching multiplexer client command from the
    agent's shell (those block without a real TTY). It only creates detached
    sessions / tabs / panes (which work headlessly) and launches viewers via
    Start-Process, which returns immediately. Progress is tracked through plain
    files (one set per command):

        <state-dir>\status[.<i>].txt  ->  "RUNNING <pid> <iso>" then "DONE <code> <iso>"
        <state-dir>\log[.<i>].txt     ->  full captured output (live)

    Poll those files (e.g. with Wait-LongRun.ps1) to learn when each command
    finished and with what exit code -- no multiplexer call required.

.PARAMETER Command
    One or more command lines to run, each in its own pane. Provide extra
    commands as additional positional arguments (place named parameters such as
    -Session / -WorkingDirectory / -NoViewer before them). Passed through
    verbatim, so a Chromium-style `cmd.exe /c "...&& autoninja ..."` invocation
    works unchanged. The exit code reported for a pane is the exit code of its
    command (its last native process).

.PARAMETER Session
    Multiplexer session/tab name. Defaults to a readable slug derived from the
    first command plus a short timestamp, e.g.
    `lr-autoninja-content-browsertests-231210`.

.PARAMETER WorkingDirectory
    Directory to run the commands in. Defaults to the current directory.

.PARAMETER NoViewer
    Prepare and start the job(s) but do not open a viewer window. With psmux the
    job runs fully headless (the detached session hosts it). With zellij a
    hidden pwsh console is started because zellij needs a real TTY to host a
    session; attach later with `zellij attach <session>`.

.OUTPUTS
    Prints a machine-readable block the caller parses:
        LONGRUN_MUX=<psmux|zellij>
        LONGRUN_SESSION=<name>
        LONGRUN_DIR=<state dir>
        LONGRUN_COUNT=<number of commands>
        LONGRUN_STATUS=<status file>     (only when a single command)
        LONGRUN_LOG=<log file>           (only when a single command)
        LONGRUN_STATUS_<i>=<status file> (one per command, 1-based)
        LONGRUN_LOG_<i>=<log file>       (one per command, 1-based)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Command,

    [string]$Session,

    [string]$WorkingDirectory = (Get-Location).Path,

    [switch]$NoViewer
)

$ErrorActionPreference = 'Stop'

function Resolve-Psmux {
    # psmux ships as psmux/pmux/tmux; prefer the psmux name.
    foreach ($name in @('psmux', 'pmux')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    $known = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\psmux.exe'
    if (Test-Path $known) { return $known }
    return $null
}

function Install-Psmux {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw @'
Neither psmux nor zellij is installed, and winget is unavailable to install
psmux automatically. Install psmux (winget id: marlocarlo.psmux, or see
https://github.com/psmux/psmux) or zellij, ensure it is on PATH, then re-run.
'@
    }
    Write-Host 'Neither psmux nor zellij found; installing psmux via winget...' -ForegroundColor Yellow
    & winget install --id marlocarlo.psmux -e --source winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-Host
    $p = Resolve-Psmux
    if ($p) { return $p }
    throw @'
psmux installation did not complete successfully. Install it manually
(winget install --id marlocarlo.psmux) or install zellij, ensure it is on PATH,
then re-run.
'@
}

function Resolve-Zellij {
    $cmd = Get-Command zellij -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $known = Join-Path $env:LOCALAPPDATA 'Zellij\zellij.exe'
    if (Test-Path $known) { return $known }
    return $null
}

function Get-CommandSlug([string]$cmd) {
    # Derive a short, readable session slug from the command so the session name
    # reflects what is running (e.g. "autoninja-content_browsertests") rather
    # than an opaque id. Focuses on the last && clause (skipping env-setup and
    # `cd` prefixes), drops shell/path/build-dir/flag noise, keeps the first few
    # meaningful tokens, and yields a mux-safe [a-z0-9_-] string.
    $clause = ($cmd -split '&&')[-1]
    $clause = $clause -replace 'cmd(\.exe)?\s*/c', ' ' -replace '["'']', ' '
    $noise = @(
        'cmd', 'exe', 'pwsh', 'powershell', 'bash', 'sh', 'call', 'set', 'echo',
        'cd', 'dir', 'rem', 'start', 'nul', 'out', 'err', 'the', 'and', 'with',
        'release', 'debug', 'x64', 'x86', 'win', 'obj', 'bin', 'src', 'tmp'
    )
    $tokens = [regex]::Matches($clause.ToLowerInvariant(), '[a-z][a-z0-9_]{2,}') |
        ForEach-Object { $_.Value }
    $picked = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tokens) {
        if ($noise -contains $t) { continue }
        if ($t -match '_x64$|_x86$') { continue }   # build dirs: release_x64, ...
        if ($t -match '^gtest_') { continue }        # gtest flags, not the target
        if ($picked -contains $t) { continue }
        $picked.Add($t)
        if ($picked.Count -ge 4) { break }
    }
    $slug = ($picked -join '-')
    if (-not $slug) { $slug = 'run' }
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).TrimEnd('-_') }
    return $slug
}

# --- Detect whether we are already inside a multiplexer session -------------
# psmux (tmux-compatible) exports TMUX inside its panes; zellij exports ZELLIJ.
$inPsmux  = [bool]$env:TMUX
$inZellij = [bool]$env:ZELLIJ
$inWt     = [bool]$env:WT_SESSION

# --- Choose the multiplexer -------------------------------------------------
# Being inside a session forces that multiplexer (so we open a tab in it);
# otherwise prefer psmux, fall back to zellij, and install psmux if neither.
if ($inPsmux) {
    $muxKind = 'psmux'
    $muxPath = Resolve-Psmux
    if (-not $muxPath) { $muxPath = Install-Psmux }
} elseif ($inZellij) {
    $muxKind = 'zellij'
    $muxPath = Resolve-Zellij
    if (-not $muxPath) { throw 'Running inside a zellij session but zellij.exe could not be located on PATH.' }
} else {
    $muxPath = Resolve-Psmux
    if ($muxPath) {
        $muxKind = 'psmux'
    } else {
        $zp = Resolve-Zellij
        if ($zp) {
            $muxKind = 'zellij'
            $muxPath = $zp
        } else {
            $muxKind = 'psmux'
            $muxPath = Install-Psmux
        }
    }
}

$n = $Command.Count

if (-not $Session) {
    $Session = 'lr-{0}-{1}' -f (Get-CommandSlug $Command[0]), (Get-Date -Format 'HHmmss')
}

$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path

# Per-run state directory.
$stateRoot = Join-Path $env:TEMP 'long-run'
$stateDir = Join-Path $stateRoot $Session
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

# Wrapper template: runs one payload in its pane, tees output to the log, and
# records the exit code in the status file. Kept open at the end so the user can
# read the result; closing the pane does not kill the job mid-flight (it has
# already run) -- it only detaches the viewer.
function New-Wrapper([string]$statusFile, [string]$logFile, [string]$payloadFile, [string]$workdir, [string]$label) {
    return @'
$ErrorActionPreference = 'Continue'
$statusFile = {0}
$logFile    = {1}
$payload    = {2}
$workdir    = {3}
$session    = {4}

Set-Location -LiteralPath $workdir
"RUNNING $PID $([DateTime]::UtcNow.ToString('o'))" | Set-Content -LiteralPath $statusFile -Encoding utf8
Write-Host "==> long-run [$session] started in $workdir" -ForegroundColor Cyan
Write-Host "==> command:" -ForegroundColor Cyan
Get-Content -LiteralPath $payload | ForEach-Object {{ Write-Host "    $_" }}
Write-Host ''

$global:LASTEXITCODE = 0
$code = 0
try {{
    . $payload *>&1 | Tee-Object -FilePath $logFile
    $code = $LASTEXITCODE
    if ($null -eq $code) {{ $code = 0 }}
}} catch {{
    ($_ | Out-String) | Tee-Object -FilePath $logFile -Append | Write-Host
    $code = 1
}}

"DONE $code $([DateTime]::UtcNow.ToString('o'))" | Set-Content -LiteralPath $statusFile -Encoding utf8
Write-Host ''
if ($code -eq 0) {{
    Write-Host "==> long-run [$session] finished OK (exit 0)" -ForegroundColor Green
}} else {{
    Write-Host "==> long-run [$session] FAILED (exit $code)" -ForegroundColor Red
}}
Write-Host 'Press Enter to close this pane (the job has already completed).'
[void](Read-Host)
'@ -f (
        "'" + ($statusFile -replace "'", "''") + "'"),
        ("'" + ($logFile -replace "'", "''") + "'"),
        ("'" + ($payloadFile -replace "'", "''") + "'"),
        ("'" + ($workdir -replace "'", "''") + "'"),
        ("'" + ($label -replace "'", "''") + "'")
}

# Prepare per-command payload/wrapper/status/log files. When there is a single
# command, use the legacy unindexed names (status.txt / log.txt) for
# compatibility; otherwise index each set (status.1.txt, log.1.txt, ...).
$wrapperFiles = @()
$statusFiles = @()
$logFiles = @()
for ($i = 0; $i -lt $n; $i++) {
    $idx = $i + 1
    $suffix = if ($n -eq 1) { '' } else { ".$idx" }
    $payloadFile = Join-Path $stateDir "command$suffix.ps1"
    $wrapperFile = Join-Path $stateDir "wrapper$suffix.ps1"
    $statusFile = Join-Path $stateDir "status$suffix.txt"
    $logFile = Join-Path $stateDir "log$suffix.txt"
    $label = if ($n -eq 1) { $Session } else { "$Session#$idx" }

    Set-Content -LiteralPath $payloadFile -Value $Command[$i] -Encoding utf8
    Set-Content -LiteralPath $statusFile -Value 'PENDING' -Encoding utf8
    Set-Content -LiteralPath $wrapperFile -Value (New-Wrapper $statusFile $logFile $payloadFile $WorkingDirectory $label) -Encoding utf8

    $wrapperFiles += $wrapperFile
    $statusFiles += $statusFile
    $logFiles += $logFile
}

# pwsh args that run a given wrapper file.
function Get-WrapperArgs([string]$wrapperFile) {
    return @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperFile)
}

# For zellij we host every pane via a single KDL layout that runs each wrapper
# under pwsh. Backslashes must be doubled inside KDL quoted strings.
function ConvertTo-Kdl([string]$s) { $s -replace '\\', '\\' }
$layoutFile = Join-Path $stateDir 'run.kdl'
if ($muxKind -eq 'zellij') {
    $paneBlocks = foreach ($wf in $wrapperFiles) {
        $wk = ConvertTo-Kdl $wf
        @"
    pane command="pwsh" {
        args "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" "$wk"
    }
"@
    }
    $layout = "layout {`n" + ($paneBlocks -join "`n") + "`n}"
    Set-Content -LiteralPath $layoutFile -Value $layout -Encoding utf8
}

# --- Helper: resolve the wt.exe matching the Windows Terminal edition we're in
# Provided by the shared, vendored terminal helpers (Resolve-WtExe). This copy
# is kept in sync from shared\Terminal-Panes.ps1 via tools\Sync-SharedScripts.ps1
# so the plugin stays self-contained.
. (Join-Path $PSScriptRoot 'Terminal-Panes.ps1')

# --- Helper: open a viewer that runs $ViewerArgs (a program + its args) ------
# Uses a WT tab in the current window when inside Windows Terminal, otherwise a
# new pwsh window. NOTE: the generic wt.exe on PATH is a 0-byte Store
# app-execution-alias reparse point; Resolve-WtExe returns either an
# edition-specific wt.exe (full path) or 'wt.exe' launched BY NAME.
function Open-Viewer([string[]]$ViewerArgs) {
    $wtExe = Resolve-WtExe
    $hasWt = ($wtExe -ne 'wt.exe') -or [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
    if ($inWt -and $hasWt) {
        # Add a tab to the CURRENT Windows Terminal window (-w 0).
        $wtArgs = @('-w', '0', 'new-tab', '--title', $Session) + $ViewerArgs
        Start-Process -FilePath $wtExe -ArgumentList $wtArgs | Out-Null
    } else {
        # Fall back to a standalone pwsh console window hosting the viewer.
        $prog = $ViewerArgs[0]
        $rest = @($ViewerArgs | Select-Object -Skip 1)
        $inner = "& '$($prog -replace "'", "''")'"
        foreach ($a in $rest) { $inner += " '$($a -replace "'", "''")'" }
        Start-Process -FilePath 'pwsh' -WindowStyle Normal `
            -ArgumentList @('-NoProfile', '-NoExit', '-Command', $inner) | Out-Null
    }
}

# --- Launch -----------------------------------------------------------------
# Forward the caller's environment into the psmux panes. On Windows the psmux
# (tmux) server does NOT inherit the launching client's process environment, so
# volatile, shell-injected vars (e.g. a dev shell that prepends depot_tools /
# toolchain dirs to PATH but never persists them to the User/Machine registry)
# are otherwise invisible inside a pane. tmux `-e NAME=VALUE` (supported by
# new-session/new-window/split-window in tmux 3.0+) snapshots them explicitly.
# Only forward simply-named vars (skip names with '(' like 'ProgramFiles(x86)',
# which tmux can't parse and which the server already has anyway).
$psmuxEnvArgs = @()
foreach ($ev in Get-ChildItem env:) {
    if ($ev.Name -match '^[A-Za-z_][A-Za-z0-9_]*$') {
        $psmuxEnvArgs += @('-e', "$($ev.Name)=$($ev.Value)")
    }
}

$reopenHint = ''
if ($muxKind -eq 'psmux') {
    if ($inPsmux) {
        # Already inside a psmux session: open the job as a new tab (window) in
        # the current session, then split it into one pane per extra command.
        # Rely on the inherited TMUX env to target the current session/window.
        & $muxPath new-window @psmuxEnvArgs -n $Session -- pwsh @(Get-WrapperArgs $wrapperFiles[0]) | Out-Null
        for ($k = 1; $k -lt $n; $k++) {
            & $muxPath split-window @psmuxEnvArgs -- pwsh @(Get-WrapperArgs $wrapperFiles[$k]) | Out-Null
        }
        if ($n -gt 1) { & $muxPath select-layout tiled | Out-Null }
    } else {
        # Create a DETACHED session that hosts the job(s) (works headlessly, so
        # they start immediately and are decoupled even before a viewer
        # attaches), then split in one pane per extra command.
        & $muxPath new-session @psmuxEnvArgs -s $Session -d -- pwsh @(Get-WrapperArgs $wrapperFiles[0]) | Out-Null
        for ($k = 1; $k -lt $n; $k++) {
            & $muxPath split-window @psmuxEnvArgs -t $Session -- pwsh @(Get-WrapperArgs $wrapperFiles[$k]) | Out-Null
        }
        if ($n -gt 1) { & $muxPath select-layout -t $Session tiled | Out-Null }
        if (-not $NoViewer) {
            Open-Viewer @($muxPath, 'attach', '-t', $Session)
        }
    }
    $reopenHint = "$muxPath attach -t $Session"
} else {
    # zellij: the layout already declares one pane per command.
    if ($inZellij) {
        # Already inside a zellij session: add a new tab running the layout.
        & $muxPath action new-tab --name $Session --layout $layoutFile | Out-Null
    } else {
        # Use -n/--new-session-with-layout (NOT -l): with --session, -l means
        # "add a tab to the EXISTING session", which fails for a fresh name. -n
        # always starts a new named session running the layout. zellij needs a
        # real TTY to host a session, so this must run in a viewer.
        $zjArgs = @('-s', $Session, '-n', $layoutFile)
        if ($NoViewer) {
            # Host in a hidden console (zellij can't run fully headless).
            $inner = "& '$($muxPath -replace "'", "''")' -s '$($Session -replace "'", "''")' -n '$($layoutFile -replace "'", "''")'"
            Start-Process -FilePath 'pwsh' -WindowStyle Hidden `
                -ArgumentList @('-NoProfile', '-NoExit', '-Command', $inner) | Out-Null
        } else {
            Open-Viewer (@($muxPath) + $zjArgs)
        }
    }
    $reopenHint = "$muxPath attach $Session"
}

Write-Host ''
Write-Host "LONGRUN_MUX=$muxKind"
Write-Host "LONGRUN_SESSION=$Session"
Write-Host "LONGRUN_DIR=$stateDir"
Write-Host "LONGRUN_COUNT=$n"
if ($n -eq 1) {
    Write-Host "LONGRUN_STATUS=$($statusFiles[0])"
    Write-Host "LONGRUN_LOG=$($logFiles[0])"
}
for ($i = 0; $i -lt $n; $i++) {
    $idx = $i + 1
    Write-Host "LONGRUN_STATUS_$idx=$($statusFiles[$i])"
    Write-Host "LONGRUN_LOG_$idx=$($logFiles[$i])"
}
Write-Host ''
Write-Host "Re-open a viewer any time with:  $reopenHint"
