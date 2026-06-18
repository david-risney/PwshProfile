<#
.SYNOPSIS
    Start a long-running command inside a detached zellij session and open a
    live viewer terminal (a new tab in the current Windows Terminal window when
    one is detected, otherwise a new window).

.DESCRIPTION
    The actual command runs in a zellij pane hosted by the viewer terminal.
    Because zellij uses a client/server split, closing the viewer only DETACHES
    -- the job keeps running on the zellij server and can be re-attached later
    with `zellij attach <session>`. The job is therefore decoupled from the
    Copilot CLI session and survives interrupts.

    This script itself NEVER runs an attaching zellij client command (those
    block when invoked from a process without a real TTY, such as the agent's
    shell). It only prepares files and launches the viewer via Start-Process,
    which returns immediately. Progress is tracked through plain files:

        <state-dir>\status.txt   ->  "RUNNING <pid> <iso>"  then  "DONE <code> <iso>"
        <state-dir>\log.txt      ->  full captured output (live)

    Poll those files (e.g. with Wait-LongRun.ps1) to learn when the command
    finished and with what exit code -- no zellij call required.

.PARAMETER Command
    The command line to run. Passed through verbatim, so a Chromium-style
    `cmd.exe /c "...&& autoninja ..."` invocation works unchanged. The exit code
    reported is the exit code of this command (its last native process).

.PARAMETER Session
    zellij session name. Defaults to a readable slug derived from the command
    plus a short timestamp, e.g. `lr-autoninja-content-browsertests-231210`.

.PARAMETER WorkingDirectory
    Directory to run the command in. Defaults to the current directory.

.PARAMETER NoViewer
    Prepare and start the job but do not open a viewer window. (The job still
    runs; a viewer is started in a hidden console so the session exists. Attach
    later with `zellij attach <session>`.)

.OUTPUTS
    Prints a machine-readable block the caller parses:
        LONGRUN_SESSION=<name>
        LONGRUN_DIR=<state dir>
        LONGRUN_STATUS=<status file>
        LONGRUN_LOG=<log file>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Command,

    [string]$Session,

    [string]$WorkingDirectory = (Get-Location).Path,

    [switch]$NoViewer
)

$ErrorActionPreference = 'Stop'

function Resolve-Zellij {
    $cmd = Get-Command zellij -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $known = Join-Path $env:LOCALAPPDATA 'Zellij\zellij.exe'
    if (Test-Path $known) { return $known }

    # Best-effort install (the community Windows build). If this fails, stop
    # with clear guidance rather than guessing.
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host 'zellij not found; attempting winget install...' -ForegroundColor Yellow
        & winget install --id zellij-org.zellij -e --source winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-Host
        $cmd = Get-Command zellij -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        if (Test-Path $known) { return $known }
    }

    throw @'
zellij is not installed and could not be installed automatically.
Install the Windows build of zellij (e.g. from
https://github.com/zellij-org/zellij/releases or your preferred source),
ensure zellij.exe is on PATH, then re-run.
'@
}

function Get-CommandSlug([string]$cmd) {
    # Derive a short, readable session slug from the command so the zellij
    # session name reflects what is running (e.g. "autoninja-content_browsertests")
    # rather than an opaque id. Focuses on the last && clause (skipping env-setup
    # and `cd` prefixes), drops shell/path/build-dir/flag noise, keeps the first
    # few meaningful tokens, and yields a zellij-safe [a-z0-9_-] string.
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

$zellij = Resolve-Zellij

if (-not $Session) {
    $Session = 'lr-{0}-{1}' -f (Get-CommandSlug $Command), (Get-Date -Format 'HHmmss')
}

$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path

# Per-run state directory.
$stateRoot = Join-Path $env:TEMP 'long-run'
$stateDir = Join-Path $stateRoot $Session
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$payloadFile = Join-Path $stateDir 'command.ps1'
$wrapperFile = Join-Path $stateDir 'wrapper.ps1'
$layoutFile = Join-Path $stateDir 'run.kdl'
$statusFile = Join-Path $stateDir 'status.txt'
$logFile = Join-Path $stateDir 'log.txt'

# Payload: the user's command, verbatim.
Set-Content -LiteralPath $payloadFile -Value $Command -Encoding utf8

# Seed a pending status so a poller never races a missing file.
Set-Content -LiteralPath $statusFile -Value 'PENDING' -Encoding utf8

# Wrapper: runs the payload in the viewer pane, tees output to the log, and
# records the exit code in the status file. Kept open at the end so the user can
# read the result; closing the window does not kill the job mid-flight (it has
# already run) -- it only detaches the viewer.
$wrapper = @'
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
    ("'" + ($WorkingDirectory -replace "'", "''") + "'"),
    ("'" + ($Session -replace "'", "''") + "'")

Set-Content -LiteralPath $wrapperFile -Value $wrapper -Encoding utf8

# zellij KDL layout: a single pane that runs the wrapper under pwsh. Backslashes
# must be doubled inside KDL quoted strings.
function ConvertTo-Kdl([string]$s) { $s -replace '\\', '\\' }
$wrapperKdl = ConvertTo-Kdl $wrapperFile
$layout = @"
layout {
    pane command="pwsh" {
        args "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" "$wrapperKdl"
    }
}
"@
Set-Content -LiteralPath $layoutFile -Value $layout -Encoding utf8

# Launch the viewer. The viewer process owns a real console/TTY, so zellij runs
# correctly there; Start-Process returns immediately, so the agent's shell never
# blocks. The zellij server keeps the session alive after the viewer closes.
#
# Use -n/--new-session-with-layout (NOT -l/--layout): with the --session flag,
# -l means "add a tab to the EXISTING session named X", so for a not-yet-created
# session it tries to attach and fails with "Session not found". -n always
# starts a fresh named session running the layout.
$zjArgs = @('-s', $Session, '-n', $layoutFile)

# NOTE: wt.exe on PATH is a 0-byte Store app-execution-alias reparse point.
# Start-Process must launch it BY NAME ('wt.exe') so ShellExecute resolves the
# alias -- passing Get-Command's literal Source path silently fails to spawn.
$hasWt = [bool](Get-Command wt -ErrorAction SilentlyContinue)
$launched = $false
if ($hasWt) {
    # Pick exactly ONE --window target. wt.exe rejects a duplicate -w/--window,
    # so the NoViewer (_quake) and WT_SESSION (current-window) cases must not
    # both contribute a -w.
    if ($NoViewer) {
        # Still needs a real terminal to host zellij, but keep it out of the way
        # in the dropdown "quake" window.
        $win = @('-w', '_quake')
    } elseif ($env:WT_SESSION) {
        # Inside Windows Terminal: add a tab to the CURRENT window.
        $win = @('-w', '0')
    } else {
        # Not inside WT: open a NEW Windows Terminal window (no -w).
        $win = @()
    }
    $wtArgs = $win + @('new-tab', '--title', $Session, $zellij) + $zjArgs
    Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs | Out-Null
    $launched = $true
}

if (-not $launched) {
    # No Windows Terminal available: fall back to a standalone console window
    # (zellij requires a real TTY, so this cannot be hidden).
    $inner = "& '$($zellij -replace "'", "''")' -s '$($Session -replace "'", "''")' -n '$($layoutFile -replace "'", "''")'"
    Start-Process -FilePath 'pwsh' -WindowStyle Normal `
        -ArgumentList @('-NoProfile', '-NoExit', '-Command', $inner) | Out-Null
}

Write-Host ''
Write-Host "LONGRUN_SESSION=$Session"
Write-Host "LONGRUN_DIR=$stateDir"
Write-Host "LONGRUN_STATUS=$statusFile"
Write-Host "LONGRUN_LOG=$logFile"
Write-Host ''
Write-Host "Re-open a viewer any time with:  zellij attach $Session"
