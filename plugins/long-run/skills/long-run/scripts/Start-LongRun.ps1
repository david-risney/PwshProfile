<#
.SYNOPSIS
    Run commands through an attached named psmux session.

.DESCRIPTION
    psmux remains attached to the calling Copilot shell for the lifetime of the
    command. The command runs from a temporary script so its quoting, working
    directory, environment, output, cancellation, and exit code behave like a
    normal synchronous shell invocation.

    A local watcher opens another read/write client after a configurable delay
    when the command is still running. Dragon sessions skip that local viewer;
    their remote viewing behavior will be supplied separately.
#>
[CmdletBinding(DefaultParameterSetName = 'Command')]
param(
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Command',
        ValueFromRemainingArguments = $true)]
    [string[]]$Command,

    [Parameter(Mandatory = $true, ParameterSetName = 'CommandFile')]
    [string]$CommandFile,

    [Parameter(ParameterSetName = 'CommandFile')]
    [switch]$RemoveCommandFile,

    [string]$Session,

    [string]$WorkingDirectory = (Get-Location).Path,

    [ValidateRange(0, 86400)]
    [int]$ViewerDelaySeconds = $(if ($env:LONG_RUN_VIEWER_DELAY_SECONDS) {
        [int]$env:LONG_RUN_VIEWER_DELAY_SECONDS
    } else {
        10
    }),

    [switch]$NoViewer,

    [ValidateSet('Auto', 'Always', 'Never')]
    [string]$RemoteMode = 'Auto',

    [switch]$AllowAnonymous,

    [string]$PsmuxPath,

    [string]$TtydPath,

    [string]$DevTunnelPath,

    [string]$NodePath,

    [string]$NpmPath,

    [string]$GatewayStateDirectory,

    [string]$GatewayScript = (Join-Path $PSScriptRoot 'Start-LongRunMuxGateway.ps1')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LongRun.Common.ps1')

function Resolve-Psmux {
    foreach ($name in @('psmux', 'pmux')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }

    if ($env:LOCALAPPDATA) {
        $known = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\psmux.exe'
        if (Test-Path -LiteralPath $known) { return $known }
    }

    throw 'psmux was not found. Install it with: winget install --id marlocarlo.psmux'
}

function Get-CommandSlug([string]$Text) {
    $tokens = [regex]::Matches($Text.ToLowerInvariant(), '[a-z][a-z0-9_]{2,}') |
        ForEach-Object Value |
        Where-Object { $_ -notin @('cmd', 'exe', 'pwsh', 'powershell', 'command') } |
        Select-Object -Unique -First 4
    $slug = ($tokens -join '-')
    if (-not $slug) { $slug = 'run' }
    if ($slug.Length -gt 36) { $slug = $slug.Substring(0, 36).TrimEnd('-_') }
    return $slug
}

function Quote-PowerShellLiteral([string]$Value) {
    return "'" + ($Value -replace "'", "''") + "'"
}

function Invoke-AttachedPsmux(
    [string[]]$Arguments,
    [scriptblock]$OnSessionCreated
) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PsmuxPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PSMUX_PIPE_VT'] = '1'
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start psmux.' }

    $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync(
        [Console]::OpenStandardOutput())
    $stderrCopy = $process.StandardError.BaseStream.CopyToAsync(
        [Console]::OpenStandardError())
    if ($OnSessionCreated) {
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
        while (-not $process.HasExited -and
            [DateTimeOffset]::UtcNow -lt $deadline) {
            $record = Get-LongRunPsmuxSessions $PsmuxPath |
                Where-Object Name -EQ $Session |
                Select-Object -First 1
            if ($record) {
                & $OnSessionCreated $record
                break
            }
            Start-Sleep -Milliseconds 50
        }
    }
    $cancelHandler = [ConsoleCancelEventHandler]{
        param($sender, $eventArgs)
        $eventArgs.Cancel = $true
        try {
            $process.StandardInput.BaseStream.WriteByte(3)
            $process.StandardInput.BaseStream.Flush()
        } catch { }
    }

    [Console]::add_CancelKeyPress($cancelHandler)
    try {
        $process.WaitForExit()
        [void]$stdoutCopy.GetAwaiter().GetResult()
        [void]$stderrCopy.GetAwaiter().GetResult()
        return $process.ExitCode
    } finally {
        [Console]::remove_CancelKeyPress($cancelHandler)
        $process.StandardInput.Dispose()
        $process.Dispose()
    }
}

if ($env:PSMUX_SESSION) {
    throw 'Start-LongRun.ps1 must not be nested inside an existing psmux session.'
}

$PsmuxPath = if ($PsmuxPath) {
    (Resolve-Path -LiteralPath $PsmuxPath).Path
} else {
    Resolve-Psmux
}
$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$remote = switch ($RemoteMode) {
    'Always' { $true }
    'Never' { $false }
    default { Test-LongRunRemoteSession }
}
$windowsTerminalSession = $null
$windowsTerminalPath = $null
if (-not $NoViewer -and -not $remote -and $env:WT_SESSION) {
    . (Join-Path $PSScriptRoot 'Terminal-Panes.ps1')
    $candidate = Resolve-WtExe
    if ($candidate -ne 'wt.exe' -or
        (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        $windowsTerminalSession = $env:WT_SESSION
        $windowsTerminalPath = $candidate
    }
}

$stateRoot = Join-Path $env:TEMP 'long-run'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

$ownsCommandFiles = $false
$commandFiles = @()
$stateDir = $null
$ownsStateDir = $false
$resultFiles = @()
$wrapperFiles = @()
$sessionOwnership = [pscustomobject]@{ Created = [long]0; Id = $null }
$stateToken = [guid]::NewGuid().ToString('N')
$ownerProcess = Get-Process -Id $PID
$ownerStartTimeUtcTicks = $ownerProcess.StartTime.ToUniversalTime().Ticks
$ownerPath = $ownerProcess.Path

try {
    if ($PSCmdlet.ParameterSetName -eq 'CommandFile') {
        $commandFiles = @((Resolve-Path -LiteralPath $CommandFile).Path)
        $ownsCommandFiles = $RemoveCommandFile
    } else {
        $ownsCommandFiles = $true
        foreach ($text in $Command) {
            $path = Join-Path $stateRoot ("command-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText(
                $path, $text, [System.Text.UTF8Encoding]::new($false))
            $commandFiles += $path
        }
    }

    if (-not $Session) {
        $preview = if ($Command) {
            $Command[0]
        } else {
            [System.IO.File]::ReadAllText($commandFiles[0])
        }
        $Session = 'lr-{0}-{1}' -f (
            Get-CommandSlug $preview), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    $stateDir = Get-LongRunSessionStatePath $stateRoot $Session
    if (Test-Path -LiteralPath $stateDir) {
        throw "Long-run session metadata already exists: $stateDir"
    }
    $existingSession = Get-LongRunPsmuxSessions $PsmuxPath |
        Where-Object Name -EQ $Session |
        Select-Object -First 1
    if ($existingSession) {
        throw "A psmux session named '$Session' already exists."
    }
    New-Item -ItemType Directory -Path $stateDir | Out-Null
    $ownsStateDir = $true
    [System.IO.File]::WriteAllText(
        (Join-Path $stateDir 'owner-token'),
        $stateToken,
        [System.Text.UTF8Encoding]::new($false))

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    [System.IO.File]::WriteAllText(
        (Join-Path $stateDir 'cleanup.json'),
        (@{
                commandFiles = if ($ownsCommandFiles) { $commandFiles } else { @() }
            } | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false))
    $environmentFile = Join-Path $stateDir 'environment.json'
    $environment = [ordered]@{}
    foreach ($item in Get-ChildItem Env:) {
        $environment[$item.Name] = [string]$item.Value
    }
    [System.IO.File]::WriteAllText(
        $environmentFile,
        ($environment | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false))

    for ($i = 0; $i -lt $commandFiles.Count; $i++) {
        $suffix = if ($commandFiles.Count -eq 1) { '' } else { ".$($i + 1)" }
        $resultFile = Join-Path $stateDir "result$suffix.txt"
        $wrapperFile = Join-Path $stateDir "wrapper$suffix.ps1"
        $wrapper = @"
`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $(Quote-PowerShellLiteral $WorkingDirectory)
`$savedEnvironment = Get-Content -LiteralPath $(Quote-PowerShellLiteral $environmentFile) -Raw | ConvertFrom-Json -AsHashtable
foreach (`$entry in `$savedEnvironment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable(`$entry.Key, [string]`$entry.Value, 'Process')
}
if (-not `$savedEnvironment.ContainsKey('PSMUX_PIPE_VT')) {
    [Environment]::SetEnvironmentVariable('PSMUX_PIPE_VT', `$null, 'Process')
}
`$global:LASTEXITCODE = 0
& $(Quote-PowerShellLiteral $pwshPath) -NoProfile -ExecutionPolicy Bypass -File $(Quote-PowerShellLiteral $commandFiles[$i])
`$code = if (`$null -eq `$LASTEXITCODE) { 0 } else { [int]`$LASTEXITCODE }
[System.IO.File]::WriteAllText($(Quote-PowerShellLiteral $resultFile), [string]`$code)
exit `$code
"@
        [System.IO.File]::WriteAllText($wrapperFile, $wrapper, [System.Text.UTF8Encoding]::new($false))
        $resultFiles += $resultFile
        $wrapperFiles += $wrapperFile
    }

    $entryFile = $wrapperFiles[0]
    if ($wrapperFiles.Count -gt 1) {
        $entryFile = Join-Path $stateDir 'entry.ps1'
        $splitCommands = for ($i = 1; $i -lt $wrapperFiles.Count; $i++) {
            "& $(Quote-PowerShellLiteral $PsmuxPath) split-window -- $(Quote-PowerShellLiteral $pwshPath) -NoProfile -ExecutionPolicy Bypass -File $(Quote-PowerShellLiteral $wrapperFiles[$i]) | Out-Null"
        }
        $entry = @"
`$ErrorActionPreference = 'Stop'
$($splitCommands -join [Environment]::NewLine)
& $(Quote-PowerShellLiteral $PsmuxPath) select-layout tiled | Out-Null
& $(Quote-PowerShellLiteral $pwshPath) -NoProfile -ExecutionPolicy Bypass -File $(Quote-PowerShellLiteral $wrapperFiles[0])
exit `$LASTEXITCODE
"@
        [System.IO.File]::WriteAllText($entryFile, $entry, [System.Text.UTF8Encoding]::new($false))
    }

    $gateway = $null
    if ($remote) {
        $gatewayArguments = @{
            AllowAnonymous = $AllowAnonymous
            PsmuxPath = $PsmuxPath
        }
        foreach ($entry in @{
                TtydPath = $TtydPath
                DevTunnelPath = $DevTunnelPath
                NodePath = $NodePath
                NpmPath = $NpmPath
                StateDirectory = $GatewayStateDirectory
            }.GetEnumerator()) {
            if ($entry.Value) { $gatewayArguments[$entry.Key] = $entry.Value }
        }
        try {
            $gateway = & $GatewayScript @gatewayArguments
        } catch {
            if ($RemoteMode -eq 'Always') { throw }
            Write-Warning (
                "Remote long-run access is unavailable; continuing without it: " +
                $_.Exception.Message)
            $gateway = $null
        }
    }

    $metadata = [ordered]@{
        session = $Session
        ownerPid = $PID
        workingDirectory = $WorkingDirectory
        startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        commandCount = $commandFiles.Count
        remote = $remote
        remoteUrl = if ($gateway) {
            "$($gateway.BaseUrl)/tmux/session/$Session/?accessToken=$([uri]::EscapeDataString($gateway.TerminalCapability))"
        } else {
            $null
        }
        inventoryUrl = if ($gateway) { $gateway.Url } else { $null }
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $stateDir 'session.json'),
        ($metadata | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false))

    if ($gateway) {
        $remoteUrl = "$($gateway.BaseUrl)/tmux/session/$Session/?accessToken=$([uri]::EscapeDataString($gateway.TerminalCapability))"
        Write-Host "Connect remotely: $remoteUrl"
        Write-Host "Browse sessions: $($gateway.Url)"
        Write-Host "LONGRUN_REMOTE_URL=$remoteUrl"
        Write-Host "LONGRUN_TMUX_URL=$($gateway.Url)"
    }

    # Intentionally omit -d. Raw-VT mode lets a redirected Copilot tool process
    # stay attached while its open stdin pipe remains available for cancellation.
    $onSessionCreated = {
        param($record)
        $sessionOwnership.Created = $record.Created
        $sessionOwnership.Id = $record.Id
        $watcher = Join-Path $PSScriptRoot 'Watch-LongRunSession.ps1'
        $watcherCommand = @(
            "& $(Quote-PowerShellLiteral $watcher)"
            "-OwnerPid $PID"
            "-OwnerStartTimeUtcTicks $ownerStartTimeUtcTicks"
            "-OwnerPath $(Quote-PowerShellLiteral $ownerPath)"
            "-PsmuxPath $(Quote-PowerShellLiteral $PsmuxPath)"
            "-Session $(Quote-PowerShellLiteral $Session)"
            "-ExpectedCreated $($record.Created)"
            "-ExpectedId $(Quote-PowerShellLiteral $record.Id)"
            "-OwnerToken $(Quote-PowerShellLiteral $stateToken)"
            "-StateDirectory $(Quote-PowerShellLiteral $stateDir)"
            "-DelaySeconds $ViewerDelaySeconds"
        )
        if ($NoViewer -or $remote) { $watcherCommand += '-NoViewer' }
        if ($windowsTerminalSession) {
            $watcherCommand +=
                "-WindowsTerminalSession $(Quote-PowerShellLiteral $windowsTerminalSession)"
            $watcherCommand +=
                "-WindowsTerminalPath $(Quote-PowerShellLiteral $windowsTerminalPath)"
        }
        try {
            Start-LongRunDetachedPowerShell `
                -Command ($watcherCommand -join ' ') `
                -Name 'session-watcher'
        } catch {
            Write-Warning (
                'The long-run cleanup/viewer watcher could not be started; ' +
                "the command will continue: $($_.Exception.Message)")
        }
    }
    $psmuxExitCode = Invoke-AttachedPsmux -Arguments @(
            'new-session', '-s', $Session, '--',
            $pwshPath, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entryFile
        ) -OnSessionCreated $onSessionCreated

    $overall = 0
    foreach ($resultFile in $resultFiles) {
        if (-not (Test-Path -LiteralPath $resultFile)) {
            if ($overall -eq 0) {
                $overall = if ($psmuxExitCode -ne 0) { $psmuxExitCode } else { 130 }
            }
            continue
        }
        $code = 0
        if (-not [int]::TryParse(
                [System.IO.File]::ReadAllText($resultFile).Trim(),
                [ref]$code)) {
            $code = 1
        }
        if ($overall -eq 0 -and $code -ne 0) { $overall = $code }
    }
    exit $overall
} finally {
    try {
        if ($sessionOwnership.Created -gt 0) {
            Stop-LongRunPsmuxSession -PsmuxPath $PsmuxPath `
                -Session $Session `
                -ExpectedCreated $sessionOwnership.Created `
                -ExpectedId $sessionOwnership.Id | Out-Null
        }
    } catch { }

    $ownerTokenFile = if ($stateDir) { Join-Path $stateDir 'owner-token' }
    if ($ownsStateDir -and
        $ownerTokenFile -and
        (Test-Path -LiteralPath $ownerTokenFile) -and
        [System.IO.File]::ReadAllText($ownerTokenFile) -eq $stateToken) {
        Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($ownsCommandFiles) {
        foreach ($path in $commandFiles) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}
