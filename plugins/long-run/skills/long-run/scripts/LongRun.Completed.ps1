function Get-LongRunCompletedArchiveRoot {
    $base = $env:LOCALAPPDATA
    if (-not $base) {
        $base = [IO.Path]::GetTempPath()
    }
    return Join-Path $base 'long-run\completed'
}

function Invoke-WithLongRunCompletedArchiveLock {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $mutex = [Threading.Mutex]::new(
        $false,
        'Local\LongRunCompletedSessionArchive')
    $locked = $false
    try {
        try {
            $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
        } catch [Threading.AbandonedMutexException] {
            $locked = $true
        }
        if (-not $locked) {
            throw 'Timed out waiting for the completed-session archive lock.'
        }
        & $Action
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-LongRunCompletedArchiveRecords([string]$ArchiveRoot) {
    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
        return @()
    }

    $records = @()
    foreach ($directory in @(
            Get-ChildItem -LiteralPath $ArchiveRoot -Directory `
                -ErrorAction SilentlyContinue)) {
        $manifestPath = Join-Path $directory.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            if ($directory.LastWriteTimeUtc -lt
                [DateTime]::UtcNow.AddMinutes(-10)) {
                Remove-Item -LiteralPath $directory.FullName -Recurse -Force `
                    -ErrorAction SilentlyContinue
            }
            continue
        }

        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw `
                -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $completedAt = [DateTimeOffset]::Parse(
                [string]$manifest.completedAt,
                [Globalization.CultureInfo]::InvariantCulture)
            $expiresAt = [DateTimeOffset]::Parse(
                [string]$manifest.expiresAt,
                [Globalization.CultureInfo]::InvariantCulture)
            $transcriptPath = Join-Path $directory.FullName 'transcript.log'
            $bytes = if (Test-Path -LiteralPath $transcriptPath -PathType Leaf) {
                (Get-Item -LiteralPath $transcriptPath).Length
            } else {
                0L
            }
            $records += [pscustomobject]@{
                Directory = $directory.FullName
                Manifest = $manifest
                Session = [string]$manifest.session
                CompletedAt = $completedAt
                ExpiresAt = $expiresAt
                Bytes = [long]$bytes
            }
        } catch {
            if ($directory.LastWriteTimeUtc -lt
                [DateTime]::UtcNow.AddMinutes(-10)) {
                Remove-Item -LiteralPath $directory.FullName -Recurse -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
    return @($records)
}

function Get-LongRunCompletedSessionMap([string]$PsmuxPath) {
    $map = @{}
    try {
        $result = Invoke-PsmuxSetupCommand `
            -Arguments @(
                'list-sessions',
                '-F',
                "#{session_name}`t#{session_created}`t#{session_id}`t#{session_attached}"
            ) `
            -TimeoutMilliseconds 10000
        if ($result.ExitCode -eq 1) {
            return [pscustomobject]@{
                Success = $true
                Map = $map
            }
        }
        if ($result.ExitCode -ne 0) {
            throw "psmux failed to list sessions (exit $($result.ExitCode))."
        }
        foreach ($line in @($result.Output -split "`r?`n" |
                Where-Object { $_ })) {
            $parts = $line -split "`t", 4
            if ($parts.Count -lt 3) { continue }
            $map[$parts[0]] = [pscustomobject]@{
                Name = $parts[0]
                Created = [long]$parts[1]
                Id = $parts[2]
                Attached = if ($parts.Count -gt 3) {
                    [int]$parts[3]
                } else {
                    0
                }
            }
        }
    } catch {
        Write-LongRunLog -Component 'completed-session' `
            -Event 'list-failed' -Level 'warning' `
            -Data @{ errorType = $_.Exception.GetType().FullName }
        return [pscustomobject]@{
            Success = $false
            Map = $map
        }
    }
    return [pscustomobject]@{
        Success = $true
        Map = $map
    }
}

function Remove-LongRunCompletedArchiveRecord {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$PsmuxPath,
        [string]$Reason = 'cleanup'
    )

    if ($Record.Manifest.psmuxId -and $Record.Manifest.psmuxCreated) {
        $existing = Get-LongRunPsmuxSessions $PsmuxPath |
            Where-Object {
                $_.Name -eq $Record.Session -and
                $_.Created -eq [long]$Record.Manifest.psmuxCreated -and
                $_.Id -eq [string]$Record.Manifest.psmuxId
            } |
            Select-Object -First 1
        if ($existing) {
            $removed = $false
            for ($attempt = 0; $attempt -lt 3 -and -not $removed; $attempt++) {
                $removed = Stop-LongRunPsmuxSession `
                    -PsmuxPath $PsmuxPath `
                    -Session $Record.Session `
                    -ExpectedCreated ([long]$Record.Manifest.psmuxCreated) `
                    -ExpectedId ([string]$Record.Manifest.psmuxId)
                if (-not $removed) {
                    Start-Sleep -Milliseconds 100
                }
            }
            if (-not $removed) {
                throw "Failed to remove completed psmux session '$($Record.Session)'."
            }
        }
    }
    $manifestPath = Join-Path $Record.Directory 'manifest.json'
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $remainingContent = @(
            Get-ChildItem -LiteralPath $Record.Directory -Force `
                -ErrorAction SilentlyContinue |
                Where-Object FullName -NE $manifestPath)
        foreach ($item in $remainingContent) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
        $remainingContent = @(
            Get-ChildItem -LiteralPath $Record.Directory -Force `
                -ErrorAction SilentlyContinue |
                Where-Object FullName -NE $manifestPath)
        if ($remainingContent.Count -eq 0) {
            break
        }
        if ($attempt -lt 4) {
            Start-Sleep -Milliseconds 100
        }
    }
    if (@(
            Get-ChildItem -LiteralPath $Record.Directory -Force `
                -ErrorAction SilentlyContinue |
                Where-Object FullName -NE $manifestPath).Count -gt 0) {
        throw "Failed to remove completed archive '$($Record.Directory)'."
    }
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Record.Directory -Force `
        -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Record.Directory) {
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            [IO.File]::WriteAllText(
                $manifestPath,
                ($Record.Manifest | ConvertTo-Json -Depth 4),
                [Text.UTF8Encoding]::new($false))
        }
        throw "Failed to remove completed archive '$($Record.Directory)'."
    }
    Write-LongRunLog -Component 'completed-session' -Event 'removed' `
        -Session $Record.Session -Data @{ reason = $Reason }
}

function Invoke-LongRunCompletedCleanupUnlocked {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$PsmuxPath,
        [int]$SessionLimit,
        [long]$StorageLimitBytes,
        [string]$RemoveSession
    )

    $now = [DateTimeOffset]::UtcNow
    $records = @(Get-LongRunCompletedArchiveRecords $ArchiveRoot)
    $sessionInventory = Get-LongRunCompletedSessionMap $PsmuxPath
    if (-not $sessionInventory.Success) {
        return
    }
    $sessionMap = $sessionInventory.Map
    $remaining = @()
    foreach ($record in $records) {
        $session = $sessionMap[$record.Session]
        $sameIdentity = $session -and $record.Manifest.psmuxId -and
            $session.Id -eq [string]$record.Manifest.psmuxId
        $reason = $null
        if ($RemoveSession -and $record.Session -eq $RemoveSession) {
            $reason = 'session-reused'
        } elseif ($record.ExpiresAt -le $now) {
            $reason = 'expired'
        } elseif ($record.Manifest.psmuxId -and -not $sameIdentity) {
            $reason = 'viewer-missing'
        }

        if ($reason) {
            Remove-LongRunCompletedArchiveRecord -Record $record `
                -PsmuxPath $PsmuxPath -Reason $reason
        } else {
            $remaining += $record
        }
    }

    $remaining = @($remaining | Sort-Object CompletedAt)
    while ($remaining.Count -gt $SessionLimit -or
        (@($remaining | Measure-Object -Property Bytes -Sum).Sum -gt
            $StorageLimitBytes)) {
        $sessionInventory = Get-LongRunCompletedSessionMap $PsmuxPath
        if (-not $sessionInventory.Success) {
            break
        }
        $sessionMap = $sessionInventory.Map
        $victim = $remaining | Where-Object {
            $session = $sessionMap[$_.Session]
            -not $session -or $session.Attached -eq 0
        } | Select-Object -First 1
        if (-not $victim) { break }
        Remove-LongRunCompletedArchiveRecord -Record $victim `
            -PsmuxPath $PsmuxPath -Reason 'budget'
        $remaining = @(
            $remaining | Where-Object Directory -NE $victim.Directory)
    }
}

function Invoke-LongRunCompletedCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$PsmuxPath,
        [int]$SessionLimit,
        [long]$StorageLimitBytes,
        [string]$RemoveSession
    )

    Invoke-WithLongRunCompletedArchiveLock {
        New-Item -ItemType Directory -Path $ArchiveRoot -Force | Out-Null
        Invoke-LongRunCompletedCleanupUnlocked `
            -ArchiveRoot $ArchiveRoot `
            -PsmuxPath $PsmuxPath `
            -SessionLimit $SessionLimit `
            -StorageLimitBytes $StorageLimitBytes `
            -RemoveSession $RemoveSession
    }
}

function Publish-LongRunCompletedSession {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$PsmuxPath,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$SourceFiles,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][int]$TtlSeconds,
        [Parameter(Mandatory = $true)][int]$SessionLimit,
        [Parameter(Mandatory = $true)][long]$StorageLimitBytes,
        [bool]$CaptureComplete
    )

    if ($TtlSeconds -le 0 -or $SourceFiles.Count -eq 0) {
        return $false
    }

    return Invoke-WithLongRunCompletedArchiveLock {
        New-Item -ItemType Directory -Path $ArchiveRoot -Force | Out-Null
        Invoke-LongRunCompletedCleanupUnlocked `
            -ArchiveRoot $ArchiveRoot `
            -PsmuxPath $PsmuxPath `
            -SessionLimit $SessionLimit `
            -StorageLimitBytes $StorageLimitBytes `
            -RemoveSession $Session

        $archiveId = [guid]::NewGuid().ToString('N')
        $archiveDirectory = Join-Path $ArchiveRoot $archiveId
        $transcriptPath = Join-Path $archiveDirectory 'transcript.log'
        $viewerPath = Join-Path $archiveDirectory 'View-CompletedSession.ps1'
        $viewerGatePath = Join-Path $archiveDirectory 'viewer.ready'
        $manifestPath = Join-Path $archiveDirectory 'manifest.json'
        New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
        $archiveSession = $null
        $retentionStage = 'archive'

        try {
            $output = [IO.File]::Open(
                $transcriptPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::Read)
            try {
                foreach ($sourceFile in $SourceFiles) {
                    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
                        continue
                    }
                    $input = [IO.File]::OpenRead($sourceFile)
                    try {
                        $input.CopyTo($output)
                    } finally {
                        $input.Dispose()
                    }
                }
                $output.Flush()
            } finally {
                $output.Dispose()
            }

            $completedAt = [DateTimeOffset]::UtcNow
            $expiresAt = $completedAt.AddSeconds($TtlSeconds)
            $viewerScript = @'
param(
    [Parameter(Mandatory = $true)][string]$TranscriptPath,
    [Parameter(Mandatory = $true)][string]$GatePath,
    [Parameter(Mandatory = $true)][int]$PublisherProcessId,
    [Parameter(Mandatory = $true)][string]$CompletedAt,
    [Parameter(Mandatory = $true)][string]$ExpiresAt,
    [Parameter(Mandatory = $true)][int]$ExitCode
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
while (-not (Test-Path -LiteralPath $GatePath -PathType Leaf)) {
    if (-not (Get-Process -Id $PublisherProcessId `
            -ErrorAction SilentlyContinue)) {
        throw 'The completed-session publisher exited before setup finished.'
    }
    Start-Sleep -Milliseconds 20
}
Write-Host ('Completed command output (exit code {0})' -f $ExitCode)
Write-Host ('Completed: {0}' -f $CompletedAt)
Write-Host ('Retained until: {0}' -f $ExpiresAt)
Write-Host ''
$inputStream = [IO.File]::Open(
    $TranscriptPath,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::ReadWrite)
try {
    $outputStream = [Console]::OpenStandardOutput()
    $inputStream.CopyTo($outputStream)
    $outputStream.Flush()
} finally {
    $inputStream.Dispose()
}
Write-Host ''
Write-Host (
    '--- command completed with exit code {0}; retained output is read-only ---' `
        -f $ExitCode)
'@
            [IO.File]::WriteAllText(
                $viewerPath,
                $viewerScript,
                [Text.UTF8Encoding]::new($false))

            $manifest = [ordered]@{
                schemaVersion = 1
                archiveId = $archiveId
                session = $Session
                completedAt = $completedAt.ToString('o')
                expiresAt = $expiresAt.ToString('o')
                exitCode = $ExitCode
                captureComplete = $CaptureComplete
                transcriptBytes = (Get-Item -LiteralPath $transcriptPath).Length
                psmuxCreated = 0
                psmuxId = $null
            }
            [IO.File]::WriteAllText(
                $manifestPath,
                ($manifest | ConvertTo-Json -Depth 4),
                [Text.UTF8Encoding]::new($false))

            Invoke-LongRunCompletedCleanupUnlocked `
                -ArchiveRoot $ArchiveRoot `
                -PsmuxPath $PsmuxPath `
                -SessionLimit $SessionLimit `
                -StorageLimitBytes $StorageLimitBytes
            if (-not (Test-Path -LiteralPath $archiveDirectory)) {
                return $false
            }

            $retentionStage = 'viewer-start'
            $start = Invoke-PsmuxSetupCommand `
                -Arguments @(
                    'new-session', '-d', '-s', $Session,
                    '-c', $WorkingDirectory, '--',
                    $PowerShellPath, '-NoLogo', '-NoProfile',
                    '-NonInteractive', '-File', $viewerPath,
                    '-TranscriptPath', $transcriptPath,
                    '-GatePath', $viewerGatePath,
                    '-PublisherProcessId', [string]$PID,
                    '-CompletedAt', $completedAt.ToString('o'),
                    '-ExpiresAt', $expiresAt.ToString('o'),
                    '-ExitCode', [string]$ExitCode
                ) `
                -TimeoutMilliseconds 15000
            if ($start.ExitCode -ne 0) {
                throw "psmux failed to start the completed viewer (exit $($start.ExitCode))."
            }

            $retentionStage = 'session-discovery'
            $archiveSession = Get-LongRunPsmuxSessions $PsmuxPath |
                Where-Object Name -EQ $Session | Select-Object -First 1
            if (-not $archiveSession) {
                throw "The completed viewer did not create session '$Session'."
            }
            $manifest.psmuxCreated = $archiveSession.Created
            $manifest.psmuxId = $archiveSession.Id
            [IO.File]::WriteAllText(
                $manifestPath,
                ($manifest | ConvertTo-Json -Depth 4),
                [Text.UTF8Encoding]::new($false))

            $target = if ($archiveSession.Id) {
                $archiveSession.Id
            } else {
                $Session
            }
            $retentionStage = 'remain-on-exit'
            $remainResult = Invoke-PsmuxSetupCommand `
                -Arguments @(
                    'set-option', '-w', '-t', $target,
                    'remain-on-exit', 'on') `
                -TimeoutMilliseconds 10000
            if ($remainResult.ExitCode -ne 0) {
                throw "psmux failed to retain the completed pane (exit $($remainResult.ExitCode))."
            }
            $retentionStage = 'metadata'
            foreach ($option in @(
                    @('set-option', '-t', $target,
                        '@long-run-state', 'completed'),
                    @('set-option', '-t', $target,
                        '@long-run-completed-at', $completedAt.ToString('o')),
                    @('set-option', '-t', $target,
                        '@long-run-expires-at', $expiresAt.ToString('o')),
                    @('set-option', '-t', $target,
                        '@long-run-exit-code', [string]$ExitCode),
                    @('set-option', '-t', $target,
                        '@long-run-archive-id', $archiveId),
                    @('set-option', '-t', $target,
                        'status', 'off'),
                    @('set-option', '-w', '-t', $target,
                        'history-limit', '50000'))) {
                $setResult = Invoke-PsmuxSetupCommand `
                    -Arguments $option `
                    -TimeoutMilliseconds 10000
                if ($setResult.ExitCode -ne 0) {
                    Write-LongRunLog -Component 'completed-session' `
                        -Event 'set-option-failed' -Level 'warning' `
                        -Session $Session `
                        -Data @{ exitCode = $setResult.ExitCode }
                }
            }
            Write-LongRunLog -Component 'completed-session' `
                -Event 'retained' -Session $Session `
                -Data @{ exitCode = $ExitCode }
            try {
                $watcherPath = Join-Path $PSScriptRoot `
                    'Watch-LongRunCompletedSessions.ps1'
                $watcherCommand = '& {0} -ArchiveRoot {1} -PsmuxPath {2} *> $null' -f (
                    ConvertTo-LongRunPowerShellLiteral $watcherPath),
                    (ConvertTo-LongRunPowerShellLiteral $ArchiveRoot),
                    (ConvertTo-LongRunPowerShellLiteral $PsmuxPath)
                Start-LongRunDetachedPowerShell `
                    -Command $watcherCommand `
                    -Name 'completed-session expiry watcher'
            } catch {
                Write-LongRunLog -Component 'completed-session' `
                    -Event 'watcher-start-failed' -Level 'warning' `
                    -Session $Session `
                    -Data @{ errorType = $_.Exception.GetType().FullName }
                throw
            }
            $retentionStage = 'release'
            [IO.File]::WriteAllText(
                $viewerGatePath,
                'ready',
                [Text.UTF8Encoding]::new($false))
            return $true
        } catch {
            $retentionError = $_
            $archivePreserved = $false
            if ($archiveSession) {
                try {
                    Remove-LongRunCompletedArchiveRecord `
                        -Record ([pscustomobject]@{
                            Directory = $archiveDirectory
                            Manifest = $manifest
                            Session = $Session
                        }) `
                        -PsmuxPath $PsmuxPath `
                        -Reason 'rollback'
                } catch {
                    $archivePreserved = $true
                    Write-LongRunLog -Component 'completed-session' `
                        -Event 'rollback-remove-failed' -Level 'warning' `
                        -Session $Session `
                        -Data @{ errorType = $_.Exception.GetType().FullName }
                }
            }
            if (-not $archivePreserved -and
                (Test-Path -LiteralPath $archiveDirectory)) {
                Remove-Item -LiteralPath $archiveDirectory -Recurse -Force `
                    -ErrorAction SilentlyContinue
            }
            Write-LongRunLog -Component 'completed-session' `
                -Event 'retain-failed' -Level 'warning' -Session $Session `
                -Data @{
                    errorType = $retentionError.Exception.GetType().FullName
                    stage = $retentionStage
                }
            return $false
        }
    }
}
