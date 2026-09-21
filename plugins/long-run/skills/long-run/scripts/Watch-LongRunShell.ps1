[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PsmuxPath,

    [Parameter(Mandatory = $true)]
    [string]$Session,

    [Parameter(Mandatory = $true)]
    [long]$ExpectedCreated,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedId,

    [Parameter(Mandatory = $true)]
    [string]$OwnerToken,

    [Parameter(Mandatory = $true)]
    [string]$StateDirectory
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LongRun.Common.ps1')
Write-LongRunLog -Component 'shell-watcher' -Event 'started' -Session $Session

while ($true) {
    try {
        $record = Get-LongRunPsmuxSessions $PsmuxPath |
            Where-Object Name -EQ $Session |
            Select-Object -First 1
    } catch {
        Write-LongRunLog -Component 'shell-watcher' `
            -Event 'session-inspection-failed' -Level 'warning' -Session $Session `
            -Data @{ errorType = $_.Exception.GetType().FullName }
        Start-Sleep -Seconds 1
        continue
    }
    if (-not $record -or
        $record.Created -ne $ExpectedCreated -or
        $record.Id -ne $ExpectedId) {
        break
    }
    Start-Sleep -Seconds 1
}

Write-LongRunLog -Component 'shell-watcher' -Event 'session-ended' -Session $Session
$ownerTokenFile = Join-Path $StateDirectory 'owner-token'
if ((Test-Path -LiteralPath $ownerTokenFile) -and
    [System.IO.File]::ReadAllText($ownerTokenFile) -eq $OwnerToken) {
    Remove-Item -LiteralPath $StateDirectory -Recurse -Force `
        -ErrorAction SilentlyContinue
    Write-LongRunLog -Component 'shell-watcher' -Event 'state-cleanup-completed' `
        -Session $Session `
        -Data @{ stateRemoved = -not (Test-Path -LiteralPath $StateDirectory) }
}
