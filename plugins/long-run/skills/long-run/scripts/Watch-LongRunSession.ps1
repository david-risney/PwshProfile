[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$OwnerPid,

    [Parameter(Mandatory = $true)]
    [long]$OwnerStartTimeUtcTicks,

    [Parameter(Mandatory = $true)]
    [string]$OwnerPath,

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
    [string]$StateDirectory,

    [ValidateRange(0, 86400)]
    [int]$DelaySeconds = 10,

    [switch]$NoViewer,

    [string]$WindowsTerminalSession,

    [string]$WindowsTerminalPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LongRun.Common.ps1')
Write-LongRunLog -Component 'command-watcher' -Event 'started' -Session $Session `
    -Data @{ ownerPid = $OwnerPid; viewerEnabled = (-not $NoViewer) }

function Test-Owner {
    return Test-LongRunProcessIdentity `
        -ProcessId $OwnerPid `
        -ExpectedStartTimeUtcTicks $OwnerStartTimeUtcTicks `
        -ExpectedPath $OwnerPath
}

function Test-Session {
    try {
        $record = Get-LongRunPsmuxSessions $PsmuxPath |
            Where-Object Name -EQ $Session |
            Select-Object -First 1
        return $record -and
            $record.Created -eq $ExpectedCreated -and
            $record.Id -eq $ExpectedId
    } catch {
        Write-LongRunLog -Component 'command-watcher' `
            -Event 'session-inspection-failed' -Level 'warning' -Session $Session `
            -Data @{ errorType = $_.Exception.GetType().FullName }
        return $null
    }
}

function Remove-OwnedState {
    $ownerTokenFile = Join-Path $StateDirectory 'owner-token'
    if (-not (Test-Path -LiteralPath $ownerTokenFile) -or
        [System.IO.File]::ReadAllText($ownerTokenFile) -ne $OwnerToken) {
        return
    }
    $commandFiles = @()
    $cleanupFile = Join-Path $StateDirectory 'cleanup.json'
    if (Test-Path -LiteralPath $cleanupFile) {
        try {
            $cleanup = Get-Content -LiteralPath $cleanupFile -Raw | ConvertFrom-Json
            $commandFiles = @($cleanup.commandFiles)
        } catch { }
    }
    Remove-Item -LiteralPath $StateDirectory -Recurse -Force `
        -ErrorAction SilentlyContinue
    foreach ($commandFile in $commandFiles) {
        Remove-Item -LiteralPath $commandFile -Force -ErrorAction SilentlyContinue
    }
}

function Open-Viewer {
    Open-LongRunPsmuxClient -PsmuxPath $PsmuxPath -Session $Session `
        -WindowsTerminalPath $WindowsTerminalPath | Out-Null
}

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($DelaySeconds)
$viewerHandled = $NoViewer

$sessionDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
while ($true) {
    $sessionRunning = Test-Session
    if ($sessionRunning) { break }
    if (-not (Test-Owner)) {
        Write-LongRunLog -Component 'command-watcher' `
            -Event 'owner-exited-before-session' -Session $Session
        Remove-OwnedState
        exit 0
    }
    if ([DateTimeOffset]::UtcNow -ge $sessionDeadline) {
        Write-LongRunLog -Component 'command-watcher' `
            -Event 'session-start-timeout' -Level 'warning' -Session $Session
        exit 0
    }
    Start-Sleep -Milliseconds $(if ($null -eq $sessionRunning) { 1000 } else { 50 })
}

while ($true) {
    if (-not (Test-Owner)) {
        $removed = Stop-LongRunPsmuxSession -PsmuxPath $PsmuxPath `
            -Session $Session -ExpectedCreated $ExpectedCreated `
            -ExpectedId $ExpectedId
        Write-LongRunLog -Component 'command-watcher' -Event 'owner-exited' `
            -Session $Session -Data @{ sessionRemoved = [bool]$removed }
        Remove-OwnedState
        exit 0
    }
    $sessionRunning = Test-Session
    if ($null -eq $sessionRunning) {
        Start-Sleep -Seconds 1
        continue
    }
    if (-not $sessionRunning) {
        Write-LongRunLog -Component 'command-watcher' -Event 'session-ended' `
            -Session $Session
        exit 0
    }

    if (-not $viewerHandled -and [DateTimeOffset]::UtcNow -ge $deadline) {
        try {
            Open-Viewer
            Write-LongRunLog -Component 'command-watcher' -Event 'viewer-opened' `
                -Session $Session
        } catch {
            Write-LongRunLog -Component 'command-watcher' -Event 'viewer-open-failed' `
                -Level 'warning' -Session $Session `
                -Data @{ errorType = $_.Exception.GetType().FullName }
        }
        $viewerHandled = $true
    }
    Start-Sleep -Seconds 1
}
