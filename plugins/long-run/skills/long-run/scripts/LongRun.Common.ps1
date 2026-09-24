function Get-LongRunLogPath {
    if ($env:LONG_RUN_LOG_PATH -eq '0') { return $null }
    if ($env:LONG_RUN_LOG_PATH) { return $env:LONG_RUN_LOG_PATH }
    $root = if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'long-run\logs'
    } else {
        Join-Path $env:TEMP 'long-run-logs'
    }
    return Join-Path $root 'events.jsonl'
}

function Get-LongRunGatewayLogPath([string]$StateDirectory) {
    $logPath = Get-LongRunLogPath
    if (-not $logPath) { return $null }
    $directory = Split-Path -Parent $logPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($logPath)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $stateHash = (
            [BitConverter]::ToString($sha256.ComputeHash(
                [Text.Encoding]::UTF8.GetBytes(
                    $StateDirectory.ToLowerInvariant()))) `
                -replace '-', ''
        ).Substring(0, 12).ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
    return Join-Path $directory "$name.gateway-$stateHash.jsonl"
}

function Write-LongRunLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [string]$Event,

        [ValidateSet('debug', 'info', 'warning', 'error')]
        [string]$Level = 'info',

        [string]$Session,

        [hashtable]$Data = @{}
    )

    $mutex = $null
    $locked = $false
    try {
        $logPath = Get-LongRunLogPath
        if (-not $logPath) { return }
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            level = $Level
            component = $Component
            event = $Event
            pid = $PID
        }
        if ($Session) {
            $sessionBytes = [Text.Encoding]::UTF8.GetBytes($Session)
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try {
                $entry.sessionHash = (
                    [BitConverter]::ToString($sha256.ComputeHash($sessionBytes)) `
                        -replace '-', ''
                ).Substring(0, 16).ToLowerInvariant()
            } finally {
                $sha256.Dispose()
            }
        }
        $allowedDataKeys = [Collections.Generic.HashSet[string]]::new(
            [string[]]@(
                'reason', 'remote', 'cwd', 'errorType', 'localOnly', 'port',
                'gatewayPid', 'tunnelPid', 'viewerDelaySeconds', 'exitCode',
                'timedOut', 'removed', 'stateRemoved', 'remainingCommandFiles',
                'openedLocally', 'ownerPid', 'viewerEnabled', 'sessionRemoved',
                'index', 'candidateCount', 'reusedTunnel', 'stage', 'attempt'
            ),
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($item in $Data.GetEnumerator()) {
            if (-not $allowedDataKeys.Contains([string]$item.Key)) { continue }
            $entry[$item.Key] = $item.Value
        }
        $line = ($entry | ConvertTo-Json -Compress -Depth 10) +
            [Environment]::NewLine
        $mutex = [Threading.Mutex]::new($false, 'Local\LongRunDiagnosticsLog')
        try {
            $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(2))
        } catch [System.Threading.AbandonedMutexException] {
            $locked = $true
        }
        if (-not $locked) { return }
        $directory = Split-Path -Parent $logPath
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        if ((Test-Path -LiteralPath $logPath) -and
            (Get-Item -LiteralPath $logPath).Length -ge 5MB) {
            $archive = "$logPath.1"
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $logPath -Destination $archive -Force
        }
        [System.IO.File]::AppendAllText(
            $logPath,
            $line,
            [System.Text.UTF8Encoding]::new($false))
    } catch {
        # Diagnostics must never change command behavior.
    } finally {
        if ($mutex) {
            if ($locked) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

function Resolve-LongRunCommandPath {
    param(
        [string]$ExplicitPath,
        [string[]]$Names,
        [string]$InstallHint
    )

    if ($ExplicitPath) {
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw "$($Names[0]) was not found. $InstallHint"
}

function Resolve-LongRunShellPath([string]$ExplicitPath) {
    if ($ExplicitPath) {
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    foreach ($name in @('pwsh', 'powershell', 'cmd')) {
        $command = Get-Command $name -CommandType Application `
            -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw 'No interactive shell was found (tried pwsh, powershell, and cmd).'
}

function Test-LongRunInteractiveEnvironmentVariable([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name -notmatch (
        '^(?i:' +
        'CI|' +
        'NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|' +
        'PWSH_PROFILE_MINIMAL|' +
        'PSMUX_(?!CONFIG_FILE$|PICKER_SCRIPT$).*|TMUX|TMUX_PANE|' +
        'COPILOT_.*|DRAGON_.*|DRAGON-SERVER|' +
        'GIT_ASKPASS|GIT_TERMINAL_PROMPT|GIT_CONFIG_.*|' +
        'GH_PROMPT_DISABLED|SSH_ASKPASS|' +
        'WT_SESSION|WT_PROFILE_ID' +
        ')$')
}

function Get-LongRunInteractiveEnvironment {
    $environment = [ordered]@{}
    foreach ($item in Get-ChildItem Env:) {
        if (Test-LongRunInteractiveEnvironmentVariable $item.Name) {
            $environment[$item.Name] = [string]$item.Value
        }
    }
    return $environment
}

function Initialize-LongRunHiddenProcessStartInfo(
    [System.Diagnostics.ProcessStartInfo]$StartInfo
) {
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
}

function New-LongRunHiddenProcessStartupInformation {
    return New-CimInstance -ClassName Win32_ProcessStartup `
        -Property @{ ShowWindow = [uint16]0 } -ClientOnly
}

function Invoke-LongRunProcessWithEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Environment
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    Initialize-LongRunHiddenProcessStartInfo $startInfo
    if ([System.IO.Path]::GetExtension($FilePath) -match '^(?i:\.cmd|\.bat)$') {
        $startInfo.FileName = $env:ComSpec
        [void]$startInfo.ArgumentList.Add('/d')
        [void]$startInfo.ArgumentList.Add('/s')
        [void]$startInfo.ArgumentList.Add('/c')
        [void]$startInfo.ArgumentList.Add($FilePath)
    } else {
        $startInfo.FileName = $FilePath
    }
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment.Clear()
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $process) {
        throw "Failed to start '$FilePath'."
    }
    try {
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Get-LongRunCommandSessionName([string]$Command) {
    $tokens = [regex]::Matches(
        $Command.ToLowerInvariant(),
        '[a-z][a-z0-9_]{2,}') |
        ForEach-Object Value |
        Where-Object {
            $_ -notin @('cmd', 'exe', 'pwsh', 'powershell', 'command')
        } |
        Select-Object -Unique -First 4
    $slug = ($tokens -join '-')
    if (-not $slug) { $slug = 'run' }
    if ($slug.Length -gt 36) {
        $slug = $slug.Substring(0, 36).TrimEnd('-_')
    }
    return 'lr-{0}-{1}' -f (
        $slug), ([guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Open-LongRunPsmuxClient {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PsmuxPath,

        [Parameter(Mandatory = $true)]
        [string]$Session,

        [string]$WindowsTerminalPath
    )

    if (-not $WindowsTerminalPath) {
        . (Join-Path $PSScriptRoot 'Terminal-Panes.ps1')
        $candidate = Resolve-WtExe
        if ($candidate -ne 'wt.exe' -or
            (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
            $WindowsTerminalPath = $candidate
        }
    }
    if ($WindowsTerminalPath) {
        Start-Process -FilePath $WindowsTerminalPath -ArgumentList @(
            '-w', '0', 'new-tab', '--title', $Session,
            "`"$PsmuxPath`"", 'attach-session', '-t', $Session
        ) | Out-Null
        return 'Windows Terminal'
    }

    $command = "& '$($PsmuxPath -replace "'", "''")' attach-session -t '$($Session -replace "'", "''")'"
    $encoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath (Resolve-LongRunShellPath) `
        -WindowStyle Normal -ArgumentList @(
            '-NoProfile', '-NoExit', '-EncodedCommand', $encoded
        ) | Out-Null
    return 'a new PowerShell window'
}

function ConvertTo-LongRunPowerShellLiteral([string]$Value) {
    return "'" + ($Value -replace "'", "''") + "'"
}

function Test-LongRunSessionName([string]$Session) {
    return $Session -match '^[A-Za-z0-9_.-]+$' -and
        $Session -notin @('.', '..') -and
        -not $Session.EndsWith('.') -and
        $Session -notmatch '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'
}

function Test-LongRunPsmuxSessionExists(
    [string]$PsmuxPath,
    [string]$Session
) {
    & $PsmuxPath has-session -t $Session 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) { return $true }
    if ($exitCode -eq 1) { return $false }
    throw "psmux failed to inspect session '$Session' (exit code $exitCode)."
}

function Get-LongRunSessionStatePath([string]$Root, [string]$Session) {
    if (-not (Test-LongRunSessionName $Session)) {
        throw 'Session names may contain only letters, numbers, dot, underscore, and dash, and may not be "." or "..".'
    }
    $canonicalRoot = ConvertTo-LongRunCanonicalPath $Root
    $statePath = ConvertTo-LongRunCanonicalPath (Join-Path $canonicalRoot $Session)
    if (-not [string]::Equals(
            (Split-Path -Parent $statePath),
            $canonicalRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The session state directory must be a direct child of the state root.'
    }
    return $statePath
}

function Get-LongRunCopilotWorkspace {
    $sessionId = $env:COPILOT_AGENT_SESSION_ID
    if (-not $sessionId) { return $null }
    $copilotHome = if ($env:COPILOT_HOME) {
        $env:COPILOT_HOME
    } else {
        Join-Path $env:USERPROFILE '.copilot'
    }
    $workspacePath = Join-Path $copilotHome "session-state\$sessionId\workspace.yaml"
    if (-not (Test-Path -LiteralPath $workspacePath)) { return $null }

    $result = [ordered]@{
        Path = $workspacePath
        ClientName = $null
        RemoteSteerable = $false
    }
    foreach ($line in [System.IO.File]::ReadAllLines($workspacePath)) {
        if ($line -match '^\s*client_name:\s*(.+?)\s*$') {
            $result.ClientName = $Matches[1].Trim("'`"")
        } elseif ($line -match '^\s*remote_steerable:\s*true\s*$') {
            $result.RemoteSteerable = $true
        }
    }
    return [pscustomobject]$result
}

function Test-LongRunRemoteSession {
    $workspace = Get-LongRunCopilotWorkspace
    if ($workspace -and $workspace.ClientName -match '^(?i:dragon)(?:/|$)') {
        return $true
    }
    if ($workspace -and $workspace.RemoteSteerable) {
        return $true
    }
    return [bool](
        $env:DRAGON_PORT -or
        $env:DRAGON_INSTANCE -or
        $env:DRAGON_REMOTE -or
        $env:DRAGON_SIDE_BY_SIDE -or
        ${env:DRAGON-SERVER})
}

function Get-LongRunFreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Wait-LongRunTcpPort([int]$Port, [int]$TimeoutSeconds = 15) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $task = $client.ConnectAsync('127.0.0.1', $Port)
            if ($task.Wait(250) -and $client.Connected) { return }
        } catch {
        } finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for a service on local port $Port."
}

function Stop-LongRunProcessTree {
    param(
        [int]$ProcessId,
        [long]$ExpectedStartTimeUtcTicks = 0,
        [string]$ExpectedPath
    )

    if ($ProcessId -le 0 -or
        $ExpectedStartTimeUtcTicks -le 0 -or
        -not $ExpectedPath) {
        return $false
    }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try {
        if ($process.StartTime.ToUniversalTime().Ticks -ne
            $ExpectedStartTimeUtcTicks) {
            return $false
        }
        if (-not [string]::Equals(
                $process.Path,
                $ExpectedPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $process.Kill($true)
        return $process.WaitForExit(5000)
    } catch {
        return $false
    } finally {
        $process.Dispose()
    }
}

function Test-LongRunProcessIdentity {
    param(
        [int]$ProcessId,
        [long]$ExpectedStartTimeUtcTicks,
        [string]$ExpectedPath
    )

    if ($ProcessId -le 0 -or
        $ExpectedStartTimeUtcTicks -le 0 -or
        -not $ExpectedPath) {
        return $false
    }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try {
        return (
            $process.StartTime.ToUniversalTime().Ticks -eq
                $ExpectedStartTimeUtcTicks -and
            [string]::Equals(
                $process.Path,
                $ExpectedPath,
                [StringComparison]::OrdinalIgnoreCase))
    } catch {
        return $false
    } finally {
        $process.Dispose()
    }
}

function Get-LongRunGatewayMutexName([string]$StateDirectory) {
    $StateDirectory = ConvertTo-LongRunCanonicalPath $StateDirectory
    return 'Local\LongRunMuxGateway-' + (
        [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes(
                    $StateDirectory.ToUpperInvariant()))).Substring(0, 16))
}

function ConvertTo-LongRunCanonicalPath([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::Equals(
            $fullPath,
            $root,
            [StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = $fullPath.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar)
    }
    return $fullPath
}

function Start-LongRunDetachedPowerShell {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string]$Name = 'watcher'
    )

    $hostPowerShell = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    } else {
        Join-Path $PSHOME 'powershell.exe'
    }
    $encoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($Command))
    $commandLine = '"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {1}' -f (
        $hostPowerShell -replace '"', '""'), $encoded
    $startup = New-LongRunHiddenProcessStartupInformation
    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{
                CommandLine = $commandLine
                ProcessStartupInformation = $startup
            }
        if ($result.ReturnValue -ne 0) {
            throw "Failed to start detached $Name (Win32 error $($result.ReturnValue))."
        }
    } finally {
        $startup.Dispose()
    }
}

function Start-LongRunDetachedService {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    $hostPowerShell = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    } else {
        Join-Path $PSHOME 'powershell.exe'
    }
    $runnerPath = Join-Path $StateDirectory "$Name-runner.ps1"
    $pidPath = Join-Path $StateDirectory "$Name-runner.pid"
    $stdoutPath = Join-Path $StateDirectory "$Name.out.log"
    $stderrPath = Join-Path $StateDirectory "$Name.err.log"
    $argumentText = ($Arguments | ForEach-Object {
        '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }) -join ' '
    $runner = @"
`$ErrorActionPreference = 'Stop'
[System.IO.File]::WriteAllText($(ConvertTo-LongRunPowerShellLiteral $pidPath), [string]`$PID)
`$process = Start-Process -FilePath $(ConvertTo-LongRunPowerShellLiteral $FilePath) ``
    -ArgumentList $(ConvertTo-LongRunPowerShellLiteral $argumentText) ``
    -RedirectStandardOutput $(ConvertTo-LongRunPowerShellLiteral $stdoutPath) ``
    -RedirectStandardError $(ConvertTo-LongRunPowerShellLiteral $stderrPath) ``
    -WindowStyle Hidden -PassThru -Wait
exit `$process.ExitCode
"@
    [System.IO.File]::WriteAllText(
        $runnerPath,
        $runner,
        [System.Text.UTF8Encoding]::new($false))

    $launcherPath = Join-Path $StateDirectory "start-$Name.cmd"
    $launcher = '@start "" /b "{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" >NUL 2>&1' -f (
        $hostPowerShell -replace '"', '""'), ($runnerPath -replace '"', '""')
    [System.IO.File]::WriteAllText(
        $launcherPath,
        $launcher,
        [System.Text.Encoding]::ASCII)
    $commandLine = 'cmd.exe /d /c ""{0}""' -f ($launcherPath -replace '"', '""')
    $startup = New-LongRunHiddenProcessStartupInformation
    try {
        $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{
                CommandLine = $commandLine
                ProcessStartupInformation = $startup
            }
        if ($created.ReturnValue -ne 0) {
            throw "Failed to start detached $Name runner (Win32 error $($created.ReturnValue))."
        }
    } finally {
        $startup.Dispose()
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $pidPath) {
            $runnerPid = 0
            $pidText = try {
                [System.IO.File]::ReadAllText($pidPath).Trim()
            } catch [System.IO.IOException] {
                $null
            } catch [System.UnauthorizedAccessException] {
                $null
            }
            if ($pidText -and
                [int]::TryParse($pidText, [ref]$runnerPid) -and
                (Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)) {
                return $runnerPid
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for the detached $Name runner to start."
}

function Get-LongRunPsmuxSessions([string]$PsmuxPath) {
    $lines = @(& $PsmuxPath list-sessions `
        -F "#{session_name}`t#{session_created}`t#{session_id}" 2>$null)
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 1) { return @() }
    if ($exitCode -ne 0) {
        throw "psmux failed to list sessions (exit code $exitCode)."
    }
    return @($lines | Where-Object { $_ } | ForEach-Object {
        $parts = $_ -split "`t", 3
        [pscustomobject]@{
            Name = $parts[0]
            Created = [long]$parts[1]
            Id = $parts[2]
        }
    })
}

function Stop-LongRunPsmuxSession {
    param(
        [string]$PsmuxPath,
        [string]$Session,
        [long]$ExpectedCreated = 0,
        [string]$ExpectedId
    )

    if (-not $PsmuxPath -or -not $Session) { return $false }
    $match = Get-LongRunPsmuxSessions $PsmuxPath |
        Where-Object Name -EQ $Session |
        Select-Object -First 1
    if (-not $match -or
        ($ExpectedCreated -gt 0 -and $match.Created -ne $ExpectedCreated) -or
        ($ExpectedId -and $match.Id -ne $ExpectedId)) {
        return $false
    }
    $target = if ($match.Id) { $match.Id } else { $Session }
    & $PsmuxPath kill-session -t $target 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Start-LongRunPsmuxService {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PsmuxPath,

        [Parameter(Mandatory = $true)]
        [string]$SessionPrefix,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [string]$WorkingDirectory = $StateDirectory
    )

    $hostPowerShell = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    } else {
        Join-Path $PSHOME 'powershell.exe'
    }
    $runnerPath = Join-Path $StateDirectory 'gateway-runner.ps1'
    $pidPath = Join-Path $StateDirectory 'gateway-runner.pid'
    $argumentLiteral = '@(' + (($Arguments | ForEach-Object {
        ConvertTo-LongRunPowerShellLiteral $_
    }) -join ', ') + ')'
    $runner = @"
`$ErrorActionPreference = 'Stop'
[System.IO.File]::WriteAllText($(ConvertTo-LongRunPowerShellLiteral $pidPath), [string]`$PID)
Set-Location -LiteralPath $(ConvertTo-LongRunPowerShellLiteral $WorkingDirectory)
& $(ConvertTo-LongRunPowerShellLiteral $FilePath) $argumentLiteral
exit `$LASTEXITCODE
"@
    [System.IO.File]::WriteAllText(
        $runnerPath,
        $runner,
        [System.Text.UTF8Encoding]::new($false))

    for ($number = 1; $number -le 999; $number++) {
        $session = "$SessionPrefix-$number"
        if (Get-LongRunPsmuxSessions $PsmuxPath |
            Where-Object Name -EQ $session) {
            continue
        }
        & $PsmuxPath new-session -d -s $session -- $hostPowerShell `
            -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runnerPath
        if ($LASTEXITCODE -ne 0) { continue }

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
        while ([DateTimeOffset]::UtcNow -lt $deadline) {
            $record = Get-LongRunPsmuxSessions $PsmuxPath |
                Where-Object Name -EQ $session |
                Select-Object -First 1
            $runnerPid = 0
            if ($record -and
                (Test-Path -LiteralPath $pidPath) -and
                [int]::TryParse(
                    [System.IO.File]::ReadAllText($pidPath).Trim(),
                    [ref]$runnerPid) -and
                (Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{
                    Session = $session
                    SessionCreated = $record.Created
                    SessionId = $record.Id
                    ProcessId = $runnerPid
                    RunnerPath = $runnerPath
                }
            }
            Start-Sleep -Milliseconds 100
        }
        if ($record) {
            Stop-LongRunPsmuxSession -PsmuxPath $PsmuxPath `
                -Session $session -ExpectedId $record.Id | Out-Null
        }
        throw "Timed out waiting for psmux session '$session' to start."
    }
    throw "Could not allocate a psmux session named '$SessionPrefix-{N}'."
}

function Wait-LongRunTunnelUrl {
    param(
        [int]$ProcessId,
        [string[]]$LogFiles,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        foreach ($logFile in $LogFiles) {
            if (-not (Test-Path -LiteralPath $logFile)) { continue }
            $stream = [System.IO.FileStream]::new(
                $logFile,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
            try {
                $reader = [System.IO.StreamReader]::new($stream)
                try {
                    $text = $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
            $match = [regex]::Match(
                $text,
                'https://[A-Za-z0-9.-]+\.devtunnels\.ms(?:/)?')
            if ($match.Success -and $match.Value -notmatch '-inspect\.') {
                return $match.Value.TrimEnd('/')
            }
        }
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            $details = $LogFiles |
                Where-Object { Test-Path -LiteralPath $_ } |
                ForEach-Object { [System.IO.File]::ReadAllText($_) }
            throw "devtunnel exited before publishing a URL. $($details -join ' ')"
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for devtunnel to publish its browser URL.'
}
