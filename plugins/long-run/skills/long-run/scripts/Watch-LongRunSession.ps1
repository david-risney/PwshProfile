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

$ErrorActionPreference = 'SilentlyContinue'
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
    $record = Get-LongRunPsmuxSessions $PsmuxPath |
        Where-Object Name -EQ $Session |
        Select-Object -First 1
    return $record -and
        $record.Created -eq $ExpectedCreated -and
        $record.Id -eq $ExpectedId
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
    $attachArgs = @('attach-session', '-t', $Session)

    if ($WindowsTerminalSession -and $WindowsTerminalPath) {
        Start-Process -FilePath $WindowsTerminalPath -ArgumentList (
            @('-w', '0', 'new-tab', '--title', $Session, "`"$PsmuxPath`"") + $attachArgs
        ) -ErrorAction Stop | Out-Null
    } else {
        $command = "& '$($PsmuxPath -replace "'", "''")' attach-session -t '$($Session -replace "'", "''")'"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        Start-Process -FilePath 'pwsh' -WindowStyle Normal -ArgumentList @(
            '-NoProfile', '-NoExit', '-EncodedCommand', $encoded
        ) -ErrorAction Stop | Out-Null
    }
}

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($DelaySeconds)
$viewerHandled = $NoViewer

$sessionDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
while (-not (Test-Session)) {
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
    Start-Sleep -Milliseconds 50
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
    if (-not (Test-Session)) {
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
    Start-Sleep -Milliseconds 250
}
