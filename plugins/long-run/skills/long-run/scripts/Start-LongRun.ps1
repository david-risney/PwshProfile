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

    [ValidateRange(1, 60)]
    [int]$CaptureSetupTimeoutSeconds = 10,

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
$overall = $null

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

function Quote-PowerShellLiteral([string]$Value) {
    return "'" + ($Value -replace "'", "''") + "'"
}

function Invoke-PsmuxSetupCommand(
    [string[]]$Arguments,
    [int]$TimeoutMilliseconds
) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ([System.IO.Path]::GetExtension($PsmuxPath) -match '^(?i:\.cmd|\.bat)$') {
        $startInfo.FileName = $env:ComSpec
        [void]$startInfo.ArgumentList.Add('/d')
        [void]$startInfo.ArgumentList.Add('/s')
        [void]$startInfo.ArgumentList.Add('/c')
        [void]$startInfo.ArgumentList.Add($PsmuxPath)
    } else {
        $startInfo.FileName = $PsmuxPath
    }
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Failed to start a psmux setup command.'
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $pending = [Collections.Generic.Queue[int]]::new()
            $pending.Enqueue($process.Id)
            $descendants = [Collections.Generic.List[int]]::new()
            while ($pending.Count -gt 0) {
                $parentId = $pending.Dequeue()
                foreach ($child in Get-CimInstance Win32_Process `
                    -Filter "ParentProcessId = $parentId" `
                    -ErrorAction SilentlyContinue) {
                    $descendants.Add([int]$child.ProcessId)
                    $pending.Enqueue([int]$child.ProcessId)
                }
            }
            for ($index = $descendants.Count - 1; $index -ge 0; $index--) {
                Stop-Process -Id $descendants[$index] -Force `
                    -ErrorAction SilentlyContinue
            }
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            [void]$process.WaitForExit(5000)
            [void]$stdout.Wait(1000)
            [void]$stderr.Wait(1000)
            return [pscustomobject]@{
                ExitCode = $null
                TimedOut = $true
                Output = ''
                Error = ''
            }
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            TimedOut = $false
            Output = $stdout.GetAwaiter().GetResult()
            Error = $stderr.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-AttachedPsmux(
    [string[]]$Arguments,
    [scriptblock]$OnSessionCreated,
    [string]$SessionName,
    [string[]]$TranscriptFiles = @(),
    [string[]]$TranscriptDoneFiles = @(),
    [string[]]$TranscriptFailureFiles = @(),
    [string]$AttachedFallbackFile,
    [string]$CaptureGateFile,
    [int]$SessionDiscoveryTimeoutSeconds = 10
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

    $stderrCopy = $process.StandardError.BaseStream.CopyToAsync(
        [Console]::OpenStandardError())
    $captureEnabled = $false
    try {
        if ($OnSessionCreated) {
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(
                $SessionDiscoveryTimeoutSeconds)
            while (-not $process.HasExited -and
                [DateTimeOffset]::UtcNow -lt $deadline) {
                $remaining = [Math]::Max(
                    100,
                    [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
                $probe = Invoke-PsmuxSetupCommand -Arguments @(
                    'list-sessions',
                    '-F',
                    ('#{session_name}' + "`t" +
                        '#{session_created}' + "`t" +
                        '#{session_id}')
                ) -TimeoutMilliseconds ([Math]::Min(1000, $remaining))
                $record = if (-not $probe.TimedOut -and $probe.ExitCode -eq 0) {
                    @($probe.Output -split "`r?`n" | Where-Object { $_ } |
                        ForEach-Object {
                            $fields = $_ -split "`t", 3
                            if ($fields.Count -eq 3) {
                                [pscustomobject]@{
                                    Name = $fields[0]
                                    Created = [long]$fields[1]
                                    Id = $fields[2]
                                }
                            }
                        } | Where-Object Name -EQ $SessionName |
                        Select-Object -First 1)[0]
                }
                if ($record) {
                    $captureEnabled = [bool](& $OnSessionCreated $record)
                    break
                }
                Start-Sleep -Milliseconds 50
            }
        }
    } catch {
        Write-LongRunLog -Component 'command' -Event 'capture-setup-failed' `
            -Level 'warning' -Session $SessionName `
            -Data @{ errorType = $_.Exception.GetType().FullName }
        $captureEnabled = $false
    } finally {
        if ($CaptureGateFile -and
            -not (Test-Path -LiteralPath $CaptureGateFile)) {
            [System.IO.File]::WriteAllText(
                $CaptureGateFile,
                'ready',
                [System.Text.UTF8Encoding]::new($false))
        }
    }
    $fallbackStream = $null
    if ($captureEnabled) {
        $fallbackStream = [System.IO.FileStream]::new(
            $AttachedFallbackFile,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            ([System.IO.FileShare]::ReadWrite -bor
                [System.IO.FileShare]::Delete))
    }
    $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync(
        $(if ($captureEnabled) {
            $fallbackStream
        } else {
            [Console]::OpenStandardOutput()
        }))
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
        $captureError = $null
        if ($captureEnabled) {
            $positions = @{}
            $standardOutput = [Console]::OpenStandardOutput()
            $copyAvailable = {
                foreach ($path in $TranscriptFiles) {
                    if (-not (Test-Path -LiteralPath $path)) { continue }
                    $position = if ($positions.ContainsKey($path)) {
                        [long]$positions[$path]
                    } else {
                        [long]0
                    }
                    $stream = [System.IO.FileStream]::new(
                        $path,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        ([System.IO.FileShare]::ReadWrite -bor
                            [System.IO.FileShare]::Delete))
                    try {
                        [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
                        $buffer = [byte[]]::new(8192)
                        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $standardOutput.Write($buffer, 0, $read)
                        }
                        $positions[$path] = $stream.Position
                    } finally {
                        $stream.Dispose()
                    }
                }
                $standardOutput.Flush()
            }

            while (-not $process.HasExited) {
                & $copyAvailable
                Start-Sleep -Milliseconds 20
            }
            $process.WaitForExit()
            $flushDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
            while ([DateTimeOffset]::UtcNow -lt $flushDeadline) {
                & $copyAvailable
                if (@($TranscriptFailureFiles | Where-Object {
                            Test-Path -LiteralPath $_
                        }).Count -gt 0) {
                    $captureError = 'The long-run transcript recorder failed.'
                    break
                }
                if (@($TranscriptDoneFiles | Where-Object {
                            -not (Test-Path -LiteralPath $_)
                        }).Count -eq 0) {
                    break
                }
                Start-Sleep -Milliseconds 20
            }
            & $copyAvailable
            $incompleteRecorders = @($TranscriptDoneFiles | Where-Object {
                    -not (Test-Path -LiteralPath $_)
                })
            if (-not $captureError -and $incompleteRecorders.Count -gt 0) {
                $captureError = 'The long-run transcript recorder did not finish.'
            }
        } else {
            $process.WaitForExit()
        }
        [void]$stdoutCopy.GetAwaiter().GetResult()
        [void]$stderrCopy.GetAwaiter().GetResult()
        if ($fallbackStream) {
            $fallbackStream.Flush()
            $fallbackStream.Dispose()
            $fallbackStream = $null
        }
        if ($captureError) {
            [Console]::Error.WriteLine(
                "$captureError Falling back to attached terminal output.")
            if (Test-Path -LiteralPath $AttachedFallbackFile) {
                $fallbackInput = [System.IO.File]::OpenRead($AttachedFallbackFile)
                try {
                    $fallbackInput.CopyTo([Console]::OpenStandardOutput())
                } finally {
                    $fallbackInput.Dispose()
                }
            }
            throw $captureError
        }
        return $process.ExitCode
    } finally {
        [Console]::remove_CancelKeyPress($cancelHandler)
        if ($fallbackStream) { $fallbackStream.Dispose() }
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
$transcriptFiles = @()
$transcriptDoneFiles = @()
$transcriptFailureFiles = @()
$captureReadyFiles = @()
$recorderReadyFiles = @()
$pipeCommands = @()
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
        $Session = Get-LongRunCommandSessionName $preview
    }
    $stateDir = Get-LongRunSessionStatePath $stateRoot $Session
    if (Test-Path -LiteralPath $stateDir) {
        throw "Long-run session metadata already exists: $stateDir"
    }
    $existingProbe = Invoke-PsmuxSetupCommand -Arguments @(
        'list-sessions',
        '-F',
        ('#{session_name}' + "`t" +
            '#{session_created}' + "`t" +
            '#{session_id}')
    ) -TimeoutMilliseconds ($CaptureSetupTimeoutSeconds * 1000)
    if ($existingProbe.TimedOut) {
        throw 'Timed out while checking existing psmux sessions.'
    }
    $existingSession = if ($existingProbe.ExitCode -eq 0) {
        @($existingProbe.Output -split "`r?`n" | Where-Object { $_ } |
            ForEach-Object {
                $fields = $_ -split "`t", 3
                if ($fields.Count -eq 3) {
                    [pscustomobject]@{
                        Name = $fields[0]
                        Created = [long]$fields[1]
                        Id = $fields[2]
                    }
                }
            } | Where-Object Name -EQ $Session |
            Select-Object -First 1)[0]
    }
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
    $captureGateFile = Join-Path $stateDir 'capture-ready'
    $environment = [ordered]@{}
    foreach ($item in Get-ChildItem Env:) {
        $environment[$item.Name] = [string]$item.Value
    }
    [System.IO.File]::WriteAllText(
        $environmentFile,
        ($environment | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false))
    $recorderFile = Join-Path $stateDir 'record-transcript.ps1'
    @'
param(
    [string]$TranscriptPath,
    [string]$DonePath,
    [string]$ReadyPath,
    [string]$FailurePath
)
$ErrorActionPreference = 'Stop'
$inputStream = [Console]::OpenStandardInput()
$outputStream = [System.IO.FileStream]::new(
    $TranscriptPath,
    [System.IO.FileMode]::Create,
    [System.IO.FileAccess]::Write,
    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
[System.IO.File]::WriteAllText(
    $ReadyPath,
    'ready',
    [System.Text.UTF8Encoding]::new($false))
try {
    $inputStream.CopyTo($outputStream)
    $outputStream.Flush()
    [System.IO.File]::WriteAllText(
        $DonePath,
        'done',
        [System.Text.UTF8Encoding]::new($false))
} catch {
    [System.IO.File]::WriteAllText(
        $FailurePath,
        'failed',
        [System.Text.UTF8Encoding]::new($false))
    exit 1
} finally {
    $outputStream.Dispose()
}
'@ | Set-Content -LiteralPath $recorderFile -Encoding utf8

    for ($i = 0; $i -lt $commandFiles.Count; $i++) {
        $suffix = if ($commandFiles.Count -eq 1) { '' } else { ".$($i + 1)" }
        $resultFile = Join-Path $stateDir "result$suffix.txt"
        $wrapperFile = Join-Path $stateDir "wrapper$suffix.ps1"
        $transcriptFile = Join-Path $stateDir "transcript$suffix.bin"
        $transcriptDoneFile = Join-Path $stateDir "transcript$suffix.done"
        $captureReadyFile = Join-Path $stateDir "capture$suffix.ready"
        $recorderReadyFile = Join-Path $stateDir "recorder$suffix.ready"
        $pipeCommand =
            'pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
            '-File "{0}" "{1}" "{2}" "{3}" "{4}"' -f
                ($recorderFile -replace '"', '""'),
                ($transcriptFile -replace '"', '""'),
                ($transcriptDoneFile -replace '"', '""'),
                ($recorderReadyFile -replace '"', '""'),
                (($transcriptDoneFile + '.failed') -replace '"', '""')
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
[System.IO.File]::WriteAllText(
    $(Quote-PowerShellLiteral $captureReadyFile),
    'ready',
    [System.Text.UTF8Encoding]::new(`$false))
while (-not (Test-Path -LiteralPath $(Quote-PowerShellLiteral $captureGateFile))) {
    Start-Sleep -Milliseconds 10
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
        $transcriptFiles += $transcriptFile
        $transcriptDoneFiles += $transcriptDoneFile
        $transcriptFailureFiles += ($transcriptDoneFile + '.failed')
        $captureReadyFiles += $captureReadyFile
        $recorderReadyFiles += $recorderReadyFile
        $pipeCommands += $pipeCommand
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
        Write-Host "Long-running command session: $Session"
        Write-Host "Connect remotely: $remoteUrl"
        Write-Host "Browse sessions: $($gateway.Url)"
        Write-Host "LONGRUN_REMOTE_URL=$remoteUrl"
        Write-Host "LONGRUN_TMUX_URL=$($gateway.Url)"
        [Console]::Out.Flush()
        [Console]::Error.Flush()
    }
    Write-LongRunLog -Component 'command' -Event 'starting' -Session $Session `
        -Data @{ remote = [bool]$gateway; viewerDelaySeconds = $ViewerDelaySeconds }

    # Intentionally omit -d. Raw-VT mode lets a redirected Copilot tool process
    # stay attached while its open stdin pipe remains available for cancellation.
    $onSessionCreated = {
        param($record)
        $sessionOwnership.Created = $record.Created
        $sessionOwnership.Id = $record.Id
        $setupTimeoutMilliseconds = $CaptureSetupTimeoutSeconds * 1000
        $statusResult = Invoke-PsmuxSetupCommand -Arguments @(
            'set-option', '-t', $record.Id, 'status', 'off'
        ) -TimeoutMilliseconds $setupTimeoutMilliseconds
        if ($statusResult.TimedOut -or $statusResult.ExitCode -ne 0) {
            Write-LongRunLog -Component 'command' -Event 'status-disable-failed' `
                -Level 'warning' -Session $Session `
                -Data @{
                    exitCode = $statusResult.ExitCode
                    timedOut = $statusResult.TimedOut
                }
        }
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
            Write-LongRunLog -Component 'command' -Event 'watcher-start-failed' `
                -Level 'warning' -Session $Session `
                -Data @{ errorType = $_.Exception.GetType().FullName }
            Write-Warning (
                'The long-run cleanup/viewer watcher could not be started; ' +
                "the command will continue: $($_.Exception.Message)")
        }
        $captureDeadline = [DateTimeOffset]::UtcNow.AddSeconds(
            $CaptureSetupTimeoutSeconds)
        while ([DateTimeOffset]::UtcNow -lt $captureDeadline -and
            @($captureReadyFiles | Where-Object {
                    -not (Test-Path -LiteralPath $_)
                }).Count -gt 0) {
            Start-Sleep -Milliseconds 20
        }
        $captureEnabled = @($captureReadyFiles | Where-Object {
                -not (Test-Path -LiteralPath $_)
            }).Count -eq 0
        $paneIds = if ($captureEnabled) {
            $paneResult = Invoke-PsmuxSetupCommand -Arguments @(
                'list-panes', '-t', $record.Id, '-F', '#{pane_id}'
            ) -TimeoutMilliseconds $setupTimeoutMilliseconds
            if (-not $paneResult.TimedOut -and $paneResult.ExitCode -eq 0) {
                @($paneResult.Output -split "`r?`n" | Where-Object { $_ })
            } else {
                @()
            }
        } else {
            @()
        }
        $paneIds = @($paneIds)
        if ($paneIds.Count -ne $pipeCommands.Count) {
            $captureEnabled = $false
        }
        if ($captureEnabled) {
            for ($i = 0; $i -lt $paneIds.Count; $i++) {
                $pipeResult = Invoke-PsmuxSetupCommand -Arguments @(
                    'pipe-pane', '-t', $paneIds[$i], $pipeCommands[$i]
                ) -TimeoutMilliseconds $setupTimeoutMilliseconds
                if ($pipeResult.TimedOut -or $pipeResult.ExitCode -ne 0) {
                    $captureEnabled = $false
                    break
                }
            }
        }
        if ($captureEnabled) {
            $recorderDeadline = [DateTimeOffset]::UtcNow.AddSeconds(
                $CaptureSetupTimeoutSeconds)
            while ([DateTimeOffset]::UtcNow -lt $recorderDeadline -and
                @($recorderReadyFiles | Where-Object {
                        -not (Test-Path -LiteralPath $_)
                    }).Count -gt 0) {
                Start-Sleep -Milliseconds 20
            }
            $captureEnabled = @($recorderReadyFiles | Where-Object {
                    -not (Test-Path -LiteralPath $_)
                }).Count -eq 0
        }
        if (-not $captureEnabled) {
            foreach ($paneId in $paneIds) {
                Invoke-PsmuxSetupCommand -Arguments @(
                    'pipe-pane', '-t', $paneId
                ) -TimeoutMilliseconds $setupTimeoutMilliseconds | Out-Null
            }
            Write-LongRunLog -Component 'command' -Event 'capture-unavailable' `
                -Level 'warning' -Session $Session
        }
        return $captureEnabled
    }
    $psmuxExitCode = Invoke-AttachedPsmux -Arguments @(
            'new-session', '-s', $Session, '--',
            $pwshPath, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entryFile
        ) -OnSessionCreated $onSessionCreated `
        -SessionName $Session `
        -TranscriptFiles $transcriptFiles `
        -TranscriptDoneFiles $transcriptDoneFiles `
        -TranscriptFailureFiles $transcriptFailureFiles `
        -AttachedFallbackFile (Join-Path $stateDir 'attached-output.bin') `
        -CaptureGateFile $captureGateFile `
        -SessionDiscoveryTimeoutSeconds $CaptureSetupTimeoutSeconds

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
    Write-LongRunLog -Component 'command' -Event 'completed' -Session $Session `
        -Data @{ exitCode = $overall }
    exit $overall
} catch {
    Write-LongRunLog -Component 'command' -Event 'failed' -Level 'error' `
        -Session $Session -Data @{ errorType = $_.Exception.GetType().FullName }
    throw
} finally {
    try {
        if ($sessionOwnership.Created -gt 0) {
            $removed = Stop-LongRunPsmuxSession -PsmuxPath $PsmuxPath `
                -Session $Session `
                -ExpectedCreated $sessionOwnership.Created `
                -ExpectedId $sessionOwnership.Id
            Write-LongRunLog -Component 'command' -Event 'session-cleanup' `
                -Session $Session -Data @{ removed = [bool]$removed }
        }
    } catch {
        Write-LongRunLog -Component 'command' -Event 'session-cleanup-failed' `
            -Level 'warning' -Session $Session `
            -Data @{ errorType = $_.Exception.GetType().FullName }
    }

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
    $remainingCommandFiles = @($commandFiles | Where-Object {
            Test-Path -LiteralPath $_
        }).Count
    $stateRemoved = -not $stateDir -or -not (Test-Path -LiteralPath $stateDir)
    Write-LongRunLog -Component 'command' -Event 'artifacts-cleanup-completed' `
        -Session $Session -Data @{
            stateRemoved = $stateRemoved
            remainingCommandFiles = $remainingCommandFiles
        }
}
