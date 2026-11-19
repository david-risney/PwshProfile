param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Open', 'Release', 'Delete')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$ArchiveRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-fA-F0-9]{32}$')]
    [string]$ArchiveId,

    [Parameter(Mandatory = $true)]
    [string]$PsmuxPath,

    [string]$ExpectedPsmuxId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LongRun.Common.ps1')
. (Join-Path $PSScriptRoot 'LongRun.Completed.ps1')

$requestedAction = $Action
$result = Invoke-WithLongRunCompletedArchiveLock {
    $record = Get-LongRunCompletedArchiveRecords $ArchiveRoot |
        Where-Object { $_.Manifest.archiveId -eq $ArchiveId } |
        Select-Object -First 1
    if (-not $record) {
        if ($requestedAction -eq 'Release') { return }
        throw 'The completed output archive no longer exists.'
    }
    switch ($requestedAction) {
        'Open' {
            $id = Start-LongRunCompletedViewer -Record $record `
                -PsmuxPath $PsmuxPath -PowerShellPath (Get-Process -Id $PID).Path
            @{ psmuxId = $id }
        }
        'Release' {
            if ($ExpectedPsmuxId -and
                $record.Manifest.psmuxId -eq $ExpectedPsmuxId) {
                Stop-LongRunCompletedViewer -Record $record -PsmuxPath $PsmuxPath
            }
        }
        'Delete' {
            Remove-LongRunCompletedArchiveRecord -Record $record `
                -PsmuxPath $PsmuxPath -Reason 'user'
        }
    }
}
$result | ConvertTo-Json -Compress
