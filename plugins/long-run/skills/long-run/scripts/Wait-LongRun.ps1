<#
.SYNOPSIS
    Block until a long-run job (started by Start-LongRun.ps1) finishes, then
    return its exit code. Handles jobs with multiple command panes.

.DESCRIPTION
    Polls the status file(s) written by the job's wrapper(s). This script touches
    only plain files -- it never calls the multiplexer (psmux/zellij) -- so it is
    safe to run from the agent's shell. If this wait is interrupted or times out,
    the underlying job keeps running in its multiplexer session; just call this
    again to resume waiting.

    For a single-command job it waits on `status.txt`. For a multi-command job it
    waits on every `status.<i>.txt` (or one of them, with -Index) and reports each
    pane's exit code. The overall exit code is 0 only if every pane exited 0;
    otherwise it is the first non-zero pane exit code.

.PARAMETER StatusFile
    Path to a specific status file (e.g. LONGRUN_STATUS or LONGRUN_STATUS_2).
    Alternatively pass -Session to derive it.

.PARAMETER Session
    Session name (printed as LONGRUN_SESSION). Used to locate the status/log
    files under %TEMP%\long-run\<session> when -StatusFile is not given.

.PARAMETER Index
    For a multi-command job, wait only for this 1-based pane index instead of all
    panes.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait. 0 (default) waits indefinitely. On timeout the
    script prints a notice and exits 124 while the job continues running.

.PARAMETER TailLines
    Number of trailing log lines to print per pane when the job finishes
    (default 40).

.OUTPUTS
    Prints each pane's captured log tail and `EXITCODE <n>`, and exits with the
    overall code (124 on timeout while still running).
#>
[CmdletBinding()]
param(
    [string]$StatusFile,
    [string]$Session,
    [int]$Index = 0,
    [int]$TimeoutSeconds = 0,
    [int]$TailLines = 40
)

$ErrorActionPreference = 'Stop'

# Build the list of status files to wait on.
$statusList = @()
if ($StatusFile) {
    $statusList = @($StatusFile)
} else {
    if (-not $Session) { throw 'Provide -StatusFile or -Session.' }
    $dir = Join-Path (Join-Path $env:TEMP 'long-run') $Session
    if ($Index -gt 0) {
        $statusList = @(Join-Path $dir "status.$Index.txt")
    } else {
        $single = Join-Path $dir 'status.txt'
        if (Test-Path -LiteralPath $single) {
            $statusList = @($single)
        } else {
            # Multi-command job: status.1.txt, status.2.txt, ... in numeric order.
            $statusList = @(
                Get-ChildItem -LiteralPath $dir -Filter 'status.*.txt' -ErrorAction SilentlyContinue |
                    Sort-Object { [int](($_.BaseName -split '\.')[-1]) } |
                    Select-Object -ExpandProperty FullName
            )
            if (-not $statusList) { $statusList = @($single) }  # fall back; may not exist yet
        }
    }
}

function Get-LogFile([string]$status) {
    # status.txt -> log.txt ; status.<i>.txt -> log.<i>.txt
    $name = Split-Path -Leaf $status
    $logName = $name -replace '^status', 'log'
    return Join-Path (Split-Path -Parent $status) $logName
}

$deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { [datetime]::MaxValue }

# Poll until every status file reports DONE (or timeout).
$codes = @{}
while ($true) {
    $pending = $false
    foreach ($s in $statusList) {
        if ($codes.ContainsKey($s)) { continue }
        if (Test-Path -LiteralPath $s) {
            $txt = (Get-Content -LiteralPath $s -Raw).Trim()
            if ($txt -match '^DONE\s+(-?\d+)') {
                $codes[$s] = [int]$Matches[1]
                continue
            }
        }
        $pending = $true
    }
    if (-not $pending) { break }
    if ((Get-Date) -gt $deadline) {
        Write-Host "TIMEOUT after ${TimeoutSeconds}s -- job is still running (session continues)." -ForegroundColor Yellow
        foreach ($s in $statusList) {
            $log = Get-LogFile $s
            if (Test-Path -LiteralPath $log) {
                Write-Host "----- $(Split-Path -Leaf $log) last $TailLines lines -----"
                Get-Content -LiteralPath $log -Tail $TailLines
            }
        }
        exit 124
    }
    Start-Sleep -Seconds 3
}

# All done: print each pane's tail and exit code; overall = first non-zero.
$overall = 0
$multi = $statusList.Count -gt 1
foreach ($s in $statusList) {
    $code = $codes[$s]
    if ($overall -eq 0 -and $code -ne 0) { $overall = $code }
    $log = Get-LogFile $s
    if (Test-Path -LiteralPath $log) {
        $header = if ($multi) { "----- $(Split-Path -Leaf $log) last $TailLines lines -----" } else { "----- last $TailLines log lines -----" }
        Write-Host $header
        Get-Content -LiteralPath $log -Tail $TailLines
    }
    if ($multi) {
        if ($code -eq 0) {
            Write-Host "$(Split-Path -Leaf $s): EXITCODE 0 (success)" -ForegroundColor Green
        } else {
            Write-Host "$(Split-Path -Leaf $s): EXITCODE $code (failure)" -ForegroundColor Red
        }
    }
}

Write-Host ''
if ($overall -eq 0) {
    Write-Host "EXITCODE 0 (success)" -ForegroundColor Green
} else {
    Write-Host "EXITCODE $overall (failure)" -ForegroundColor Red
}
exit $overall
