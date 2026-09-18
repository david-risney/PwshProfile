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

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'LongRun.Common.ps1')

while ($true) {
    $record = Get-LongRunPsmuxSessions $PsmuxPath |
        Where-Object Name -EQ $Session |
        Select-Object -First 1
    if (-not $record -or
        $record.Created -ne $ExpectedCreated -or
        $record.Id -ne $ExpectedId) {
        break
    }
    Start-Sleep -Seconds 1
}

$ownerTokenFile = Join-Path $StateDirectory 'owner-token'
if ((Test-Path -LiteralPath $ownerTokenFile) -and
    [System.IO.File]::ReadAllText($ownerTokenFile) -eq $OwnerToken) {
    Remove-Item -LiteralPath $StateDirectory -Recurse -Force `
        -ErrorAction SilentlyContinue
}
