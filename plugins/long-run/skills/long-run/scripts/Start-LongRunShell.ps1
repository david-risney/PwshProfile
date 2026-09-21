<#
.SYNOPSIS
    Start a persistent interactive shell in a named psmux session.

.DESCRIPTION
    Creates a detached psmux session in the requested working directory with a
    snapshot of the caller's process environment. Prefers pwsh, then Windows
    PowerShell, then cmd. The session remains available until the user exits it.

    In a remote Dragon or Copilot session, the shared mux gateway is ensured and
    a /tmux/session/<session>/ URL is returned. ttyd starts only when that URL is opened.
#>
[CmdletBinding()]
param(
    [string]$Session,

    [string]$WorkingDirectory = (Get-Location).Path,

    [ValidateSet('Auto', 'Always', 'Never')]
    [string]$RemoteMode = 'Auto',

    [ValidateRange(1, 365)]
    [int]$TunnelExpirationDays = 30,

    [ValidateRange(10, 3600)]
    [int]$TerminalStartupIdleSeconds = 120,

    [switch]$AllowAnonymous,

    [string]$PsmuxPath,

    [string]$ShellPath,

    [string]$TtydPath,

    [string]$DevTunnelPath,

    [string]$NodePath,

    [string]$NpmPath,

    [string]$GatewayStateDirectory,

    [string]$WindowsTerminalPath,

    [switch]$NoOpen,

    [string]$GatewayScript = (Join-Path $PSScriptRoot 'Start-LongRunMuxGateway.ps1')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LongRun.Common.ps1')

function Get-SafeSessionName([string]$Directory) {
    $leaf = Split-Path -Leaf $Directory
    $slug = ($leaf.ToLowerInvariant() -replace '[^a-z0-9_.-]+', '-').Trim('-')
    if (-not $slug) { $slug = 'shell' }
    if ($slug.Length -gt 32) { $slug = $slug.Substring(0, 32).TrimEnd('-') }
    return 'shell-{0}-{1}' -f $slug, ([guid]::NewGuid().ToString('N').Substring(0, 8))
}

if ($env:PSMUX_SESSION) {
    throw 'Start-LongRunShell.ps1 must not be nested inside psmux.'
}

$remote = switch ($RemoteMode) {
    'Always' { $true }
    'Never' { $false }
    default { Test-LongRunRemoteSession }
}

$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$PsmuxPath = Resolve-LongRunCommandPath $PsmuxPath @('psmux', 'pmux') `
    'Install it with: winget install --id marlocarlo.psmux'
$ShellPath = Resolve-LongRunShellPath $ShellPath

if (-not $Session) { $Session = Get-SafeSessionName $WorkingDirectory }
$stateRoot = Join-Path $env:TEMP 'long-run-shell'
$stateDir = Get-LongRunSessionStatePath $stateRoot $Session

& $PsmuxPath has-session -t $Session 2>$null
if ($LASTEXITCODE -eq 0) {
    throw "A psmux session named '$Session' already exists."
}

$ownsStateDir = $false
$stateToken = [guid]::NewGuid().ToString('N')
$ownerTokenFile = Join-Path $stateDir 'owner-token'
$sessionCreated = [long]0
$sessionId = $null
$sessionStarted = $false

try {
    Write-LongRunLog -Component 'shell' -Event 'starting' -Session $Session `
        -Data @{ remote = $remote }
    New-Item -ItemType Directory -Path $stateDir -ErrorAction Stop | Out-Null
    $ownsStateDir = $true
    [System.IO.File]::WriteAllText(
        $ownerTokenFile,
        $stateToken,
        [System.Text.UTF8Encoding]::new($false))

    $bootstrapFile = Join-Path $stateDir 'bootstrap.ps1'
    $environmentFile = Join-Path $stateDir 'environment.json'
    $metadataFile = Join-Path $stateDir 'session.json'
    $watcherPath = Join-Path $PSScriptRoot 'Watch-LongRunShell.ps1'
    $hostPowerShell = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    } else {
        Join-Path $PSHOME 'powershell.exe'
    }

    $environment = Get-LongRunInteractiveEnvironment
    [System.IO.File]::WriteAllText(
        $environmentFile,
        ($environment | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false))

    $shellName = [System.IO.Path]::GetFileNameWithoutExtension($ShellPath).ToLowerInvariant()
    $bootstrapTail = if ($shellName -eq 'cmd') {
        "& $(ConvertTo-LongRunPowerShellLiteral $ShellPath) /K"
    } else {
        "`$Host.UI.RawUI.WindowTitle = $(ConvertTo-LongRunPowerShellLiteral $Session)"
    }
    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$savedEnvironment = Get-Content -LiteralPath $(ConvertTo-LongRunPowerShellLiteral $environmentFile) -Raw | ConvertFrom-Json
foreach (`$entry in `$savedEnvironment.PSObject.Properties) {
    [Environment]::SetEnvironmentVariable(`$entry.Name, [string]`$entry.Value, 'Process')
}
if (`$env:PSMUX_CONFIG_FILE -and
    (Test-Path -LiteralPath `$env:PSMUX_CONFIG_FILE -PathType Leaf)) {
    `$psmuxConfigured = `$true
    foreach (`$entry in @{
        PSMUX_CONFIG_FILE = `$env:PSMUX_CONFIG_FILE
        PSMUX_PICKER_SCRIPT = `$env:PSMUX_PICKER_SCRIPT
    }.GetEnumerator()) {
        if (-not `$entry.Value) { continue }
        & $(ConvertTo-LongRunPowerShellLiteral $PsmuxPath) set-environment `$entry.Key `$entry.Value |
            Out-Null
        if (`$LASTEXITCODE -ne 0) { `$psmuxConfigured = `$false }
    }
    & $(ConvertTo-LongRunPowerShellLiteral $PsmuxPath) source-file `$env:PSMUX_CONFIG_FILE |
        Out-Null
    if (`$LASTEXITCODE -ne 0) { `$psmuxConfigured = `$false }
    if (-not `$psmuxConfigured) {
        Write-Warning "psmux could not load '`$env:PSMUX_CONFIG_FILE'."
    }
}
Set-Location -LiteralPath $(ConvertTo-LongRunPowerShellLiteral $WorkingDirectory)
$bootstrapTail
"@
    [System.IO.File]::WriteAllText(
        $bootstrapFile,
        $bootstrap,
        [System.Text.UTF8Encoding]::new($false))

    $sessionCommand = if ($shellName -eq 'cmd') {
        @($hostPowerShell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bootstrapFile)
    } else {
        @($ShellPath, '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $bootstrapFile)
    }
    $psmuxExitCode = Invoke-LongRunProcessWithEnvironment `
        -FilePath $PsmuxPath `
        -Arguments (@('new-session', '-d', '-s', $Session, '--') + $sessionCommand) `
        -Environment $environment
    if ($psmuxExitCode -ne 0) {
        throw "psmux failed to create session '$Session' (exit $psmuxExitCode)."
    }
    $sessionStarted = $true
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while ($sessionCreated -le 0 -and [DateTimeOffset]::UtcNow -lt $deadline) {
        $record = Get-LongRunPsmuxSessions $PsmuxPath |
            Where-Object Name -EQ $Session |
            Select-Object -First 1
        if ($record) {
            $sessionCreated = $record.Created
            $sessionId = $record.Id
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if ($sessionCreated -le 0) {
        throw "The psmux session '$Session' was created but its identity could not be verified."
    }

    $localAttach = "& $(ConvertTo-LongRunPowerShellLiteral $PsmuxPath) " +
        "attach-session -t $(ConvertTo-LongRunPowerShellLiteral $Session)"
    $remoteUrl = $null
    $inventoryUrl = $null
    if ($remote) {
        $gatewayArguments = @{
            TunnelExpirationDays = $TunnelExpirationDays
            TerminalStartupIdleSeconds = $TerminalStartupIdleSeconds
            AllowAnonymous = $AllowAnonymous
            PsmuxPath = $PsmuxPath
        }
        foreach ($entry in @{
                TtydPath = $TtydPath
                DevTunnelPath = $DevTunnelPath
                NodePath = $NodePath
                NpmPath = $NpmPath
                StateDirectory = $GatewayStateDirectory
                ShellPath = $ShellPath
            }.GetEnumerator()) {
            if ($entry.Value) { $gatewayArguments[$entry.Key] = $entry.Value }
        }
        try {
            $gateway = & $GatewayScript @gatewayArguments
            $inventoryUrl = $gateway.Url
            $remoteUrl = "$($gateway.BaseUrl)/tmux/session/$Session/?accessToken=$([uri]::EscapeDataString($gateway.TerminalCapability))"
        } catch {
            Write-LongRunLog -Component 'shell' -Event 'gateway-unavailable' `
                -Level 'warning' -Session $Session `
                -Data @{ errorType = $_.Exception.GetType().FullName }
            if ($RemoteMode -eq 'Always') { throw }
            Write-Warning (
                "Remote shell access is unavailable; continuing locally: " +
                $_.Exception.Message)
            $remote = $false
        }
    }

    $metadata = [ordered]@{
        session = $Session
        sessionCreated = $sessionCreated
        sessionId = $sessionId
        workingDirectory = $WorkingDirectory
        shellPath = $ShellPath
        startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        remote = $remote
        localAttachCommand = $localAttach
        remoteUrl = $remoteUrl
        inventoryUrl = $inventoryUrl
    }
    [System.IO.File]::WriteAllText(
        $metadataFile,
        ($metadata | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false))

    $watcherCommand = @(
        "& $(ConvertTo-LongRunPowerShellLiteral $watcherPath)"
        "-PsmuxPath $(ConvertTo-LongRunPowerShellLiteral $PsmuxPath)"
        "-Session $(ConvertTo-LongRunPowerShellLiteral $Session)"
        "-ExpectedCreated $sessionCreated"
        "-ExpectedId $(ConvertTo-LongRunPowerShellLiteral $sessionId)"
        "-OwnerToken $(ConvertTo-LongRunPowerShellLiteral $stateToken)"
        "-StateDirectory $(ConvertTo-LongRunPowerShellLiteral $stateDir)"
    ) -join ' '
    try {
        Start-LongRunDetachedPowerShell `
            -Command $watcherCommand `
            -Name 'shell-watcher'
    } catch {
        Write-LongRunLog -Component 'shell' -Event 'watcher-start-failed' `
            -Level 'warning' -Session $Session `
            -Data @{ errorType = $_.Exception.GetType().FullName }
        throw "The persistent-shell cleanup watcher could not be started: " +
            $_.Exception.Message
    }

    $openedLocally = $false
    if (-not $remote -and -not $NoOpen) {
        try {
            $terminalHost = Open-LongRunPsmuxClient `
                -PsmuxPath $PsmuxPath -Session $Session `
                -WindowsTerminalPath $WindowsTerminalPath
            Write-Host "Opened shell in $terminalHost."
            $openedLocally = $true
        } catch {
            Write-LongRunLog -Component 'shell' -Event 'local-open-failed' `
                -Level 'warning' -Session $Session `
                -Data @{ errorType = $_.Exception.GetType().FullName }
            Write-Warning (
                'The shell was created, but its local terminal could not be opened: ' +
                $_.Exception.Message)
        }
    }

    Write-Host "Shell session '$Session' started in $WorkingDirectory."
    Write-Host "Connect locally: $localAttach"
    if ($remoteUrl) {
        Write-Host "Connect remotely: $remoteUrl"
        Write-Host "Browse sessions: $inventoryUrl"
        if (-not $AllowAnonymous) {
            Write-Host 'The shared dev tunnel requires authentication with an authorized account.'
        }
    }
    Write-Host ''
    Write-Host "LONGRUN_SHELL_SESSION=$Session"
    Write-Host "LONGRUN_SHELL_LOCAL_ATTACH=$localAttach"
    Write-Host "LONGRUN_SHELL_LOCAL_OPENED=$($openedLocally.ToString().ToLowerInvariant())"
    Write-Host "LONGRUN_SHELL_REMOTE=$($remote.ToString().ToLowerInvariant())"
    if ($remoteUrl) {
        Write-Host "LONGRUN_SHELL_REMOTE_URL=$remoteUrl"
        Write-Host "LONGRUN_TMUX_URL=$inventoryUrl"
    }
    Write-Host "LONGRUN_SHELL_STATE=$stateDir"
    Write-LongRunLog -Component 'shell' -Event 'started' -Session $Session `
        -Data @{ remote = $remote; openedLocally = $openedLocally }
} catch {
    Write-LongRunLog -Component 'shell' -Event 'failed' -Level 'error' `
        -Session $Session -Data @{ errorType = $_.Exception.GetType().FullName }
    if ($sessionCreated -gt 0) {
        Stop-LongRunPsmuxSession -PsmuxPath $PsmuxPath `
            -Session $Session -ExpectedCreated $sessionCreated `
            -ExpectedId $sessionId | Out-Null
    } elseif ($sessionStarted) {
        & $PsmuxPath kill-session -t $Session 2>$null | Out-Null
    }
    if ($ownsStateDir -and
        (Test-Path -LiteralPath $ownerTokenFile) -and
        [System.IO.File]::ReadAllText($ownerTokenFile) -eq $stateToken) {
        Remove-Item -LiteralPath $stateDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    throw
}
