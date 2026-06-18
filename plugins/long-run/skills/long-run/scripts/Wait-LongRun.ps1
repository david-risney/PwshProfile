<#
.SYNOPSIS
    Block until a long-run job (started by Start-LongRun.ps1) finishes, then
    return its exit code.

.DESCRIPTION
    Polls the status file written by the job's wrapper. This script touches only
    plain files -- it never calls zellij -- so it is safe to run from the
    agent's shell. If this wait is interrupted or times out, the underlying job
    keeps running in its zellij session; just call this again to resume waiting.

.PARAMETER StatusFile
    Path to the job's status.txt (printed by Start-LongRun.ps1 as
    LONGRUN_STATUS). Alternatively pass -Session to derive it.

.PARAMETER Session
    Session name (printed as LONGRUN_SESSION). Used to locate the status/log
    files under %TEMP%\long-run\<session> when -StatusFile is not given.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait. 0 (default) waits indefinitely. On timeout the
    script prints a notice and exits 124 while the job continues running.

.PARAMETER TailLines
    Number of trailing log lines to print when the job finishes (default 40).

.OUTPUTS
    Prints the captured log tail and `EXITCODE <n>`, and exits with that code
    (124 on timeout while still running).
#>
[CmdletBinding()]
param(
    [string]$StatusFile,
    [string]$Session,
    [int]$TimeoutSeconds = 0,
    [int]$TailLines = 40
)

$ErrorActionPreference = 'Stop'

if (-not $StatusFile) {
    if (-not $Session) { throw 'Provide -StatusFile or -Session.' }
    $StatusFile = Join-Path (Join-Path $env:TEMP 'long-run') (Join-Path $Session 'status.txt')
}
$logFile = Join-Path (Split-Path -Parent $StatusFile) 'log.txt'

$deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { [datetime]::MaxValue }

$code = $null
while ($true) {
    if (Test-Path -LiteralPath $StatusFile) {
        $s = (Get-Content -LiteralPath $StatusFile -Raw).Trim()
        if ($s -match '^DONE\s+(-?\d+)') {
            $code = [int]$Matches[1]
            break
        }
    }
    if ((Get-Date) -gt $deadline) {
        Write-Host "TIMEOUT after ${TimeoutSeconds}s -- job is still running (session continues)." -ForegroundColor Yellow
        if (Test-Path -LiteralPath $logFile) {
            Write-Host "----- last $TailLines log lines -----"
            Get-Content -LiteralPath $logFile -Tail $TailLines
        }
        exit 124
    }
    Start-Sleep -Seconds 3
}

if (Test-Path -LiteralPath $logFile) {
    Write-Host "----- last $TailLines log lines -----"
    Get-Content -LiteralPath $logFile -Tail $TailLines
}
Write-Host ''
if ($code -eq 0) {
    Write-Host "EXITCODE 0 (success)" -ForegroundColor Green
} else {
    Write-Host "EXITCODE $code (failure)" -ForegroundColor Red
}
exit $code
