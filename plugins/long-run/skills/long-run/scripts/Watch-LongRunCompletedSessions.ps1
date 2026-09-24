param(
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRoot,

    [Parameter(Mandatory = $true)]
    [string]$PsmuxPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LongRun.Common.ps1')
. (Join-Path $PSScriptRoot 'LongRun.Completed.ps1')

$canonicalRoot = ConvertTo-LongRunCanonicalPath $ArchiveRoot
$rootBytes = [Text.Encoding]::UTF8.GetBytes($canonicalRoot.ToUpperInvariant())
$hash = [Security.Cryptography.SHA256]::HashData($rootBytes)
$mutexName = 'Local\LongRunCompletedSessionExpiry-' +
    [Convert]::ToHexString($hash).Substring(0, 16)
$mutex = [Threading.Mutex]::new($false, $mutexName)
$locked = $false
try {
    try {
        $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
    } catch [Threading.AbandonedMutexException] {
        $locked = $true
    }
    if (-not $locked) { exit 0 }

    while ($true) {
        $remaining = [Collections.Generic.List[object]]::new()
        Invoke-WithLongRunCompletedArchiveLock {
            $now = [DateTimeOffset]::UtcNow
            foreach ($record in @(
                    Get-LongRunCompletedArchiveRecords $canonicalRoot)) {
                if ($record.ExpiresAt -le $now) {
                    try {
                        Remove-LongRunCompletedArchiveRecord `
                            -Record $record `
                            -PsmuxPath $PsmuxPath `
                            -Reason 'expired'
                    } catch {
                        Write-LongRunLog -Component 'completed-session' `
                            -Event 'expiry-remove-failed' -Level 'warning' `
                            -Session $record.Session `
                            -Data @{
                                errorType = $_.Exception.GetType().FullName
                            }
                        $remaining.Add($record)
                    }
                } else {
                    $remaining.Add($record)
                }
            }
        }
        if ($remaining.Count -eq 0) {
            exit 0
        }

        $nextExpiry = ($remaining | Sort-Object ExpiresAt |
            Select-Object -First 1).ExpiresAt
        $seconds = [Math]::Max(
            1,
            [Math]::Min(
                30,
                [Math]::Ceiling(
                    ($nextExpiry - [DateTimeOffset]::UtcNow).TotalSeconds)))
        Start-Sleep -Seconds $seconds
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
