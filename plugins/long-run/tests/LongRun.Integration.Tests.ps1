$pluginRoot = Split-Path -Parent $PSScriptRoot
$scriptRoot = Join-Path $pluginRoot 'skills\long-run\scripts'
$startScript = Join-Path $scriptRoot 'Start-LongRun.ps1'
$env:LONG_RUN_COMPLETED_SESSION_TTL_SECONDS = '0'
$startGateway = Join-Path $scriptRoot 'Start-LongRunMuxGateway.ps1'
$stopGateway = Join-Path $scriptRoot 'Stop-LongRunMuxGateway.ps1'
$sendTtydInput = Join-Path $PSScriptRoot 'helpers\Send-TtydInput.js'
$pluginManifest = Join-Path $pluginRoot '.claude-plugin\plugin.json'
$pluginVersion = (Get-Content -LiteralPath $pluginManifest -Raw |
    ConvertFrom-Json).version
. (Join-Path $scriptRoot 'LongRun.Common.ps1')

$runCore = $env:LONG_RUN_INTEGRATION -eq '1'
$runBrowser = $env:LONG_RUN_BROWSER_INTEGRATION -eq '1'
$runUi = $env:LONG_RUN_UI_INTEGRATION -eq '1'
$runCopilot = $env:LONG_RUN_COPILOT_INTEGRATION -eq '1'
$runKnownLimits = $env:LONG_RUN_KNOWN_LIMIT_INTEGRATION -eq '1'

function Wait-LongRunIntegrationCondition(
    [scriptblock]$Condition,
    [int]$TimeoutSeconds = 15
) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function New-LongRunIntegrationRoot {
    $root = Join-Path $env:TEMP (
        'long-run-integration-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    return $root
}

function New-LongRunIntegrationSession([string]$Prefix) {
    return '{0}-{1}' -f $Prefix, [guid]::NewGuid().ToString('N').Substring(0, 10)
}

function Test-LongRunIntegrationSession([string]$PsmuxPath, [string]$Session) {
    & $PsmuxPath has-session -t $Session 2>$null
    return $LASTEXITCODE -eq 0
}

function Stop-LongRunIntegrationSession([string]$PsmuxPath, [string]$Session) {
    if (Test-LongRunIntegrationSession $PsmuxPath $Session) {
        & $PsmuxPath kill-session -t $Session 2>$null | Out-Null
    }
}

function Stop-LongRunIntegrationProcess([Diagnostics.Process]$Process) {
    if (-not $Process -or $Process.HasExited) { return }
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    [void]$Process.WaitForExit(5000)
}

function New-LongRunLauncher(
    [string]$Root,
    [string]$CommandFile,
    [string]$Session,
    [string]$PsmuxPath,
    [switch]$OpenViewer
) {
    $launcher = Join-Path $Root "launch-$Session.ps1"
    $viewer = if ($OpenViewer) {
        '-OpenViewer -ViewerDelaySeconds 1'
    } else {
        '-NoViewer'
    }
    @"
& '$($startScript.Replace("'", "''"))' ``
    -CommandFile '$($CommandFile.Replace("'", "''"))' ``
    -WorkingDirectory '$($Root.Replace("'", "''"))' ``
    -Session '$($Session.Replace("'", "''"))' ``
    -RemoteMode Never $viewer ``
    -PsmuxPath '$($PsmuxPath.Replace("'", "''"))'
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $launcher -Encoding utf8
    return $launcher
}

function Start-LongRunIntegrationProcess(
    [string]$Launcher,
    [string]$StdoutPath,
    [string]$StderrPath
) {
    return Start-Process -FilePath (Get-Command pwsh).Source `
        -ArgumentList @('-NoProfile', '-File', "`"$Launcher`"") `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath `
        -PassThru
}

function Get-LongRunIntegrationPsmux {
    $command = Get-Command psmux, pmux -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        throw 'psmux is required for long-run integration tests.'
    }
    return $command.Source
}

Describe 'Long-run real psmux integration' {
    It 'preserves cwd and environment, propagates exit code, and cleans up' `
        -Skip:(-not $runCore) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-basic'
        $commandFile = Join-Path $root 'command.ps1'
        $captureFile = Join-Path $root 'capture.json'
        $stateDir = Get-LongRunSessionStatePath (
            Join-Path $env:TEMP 'long-run') $session
        $savedValue = $env:LONG_RUN_INTEGRATION_VALUE
        try {
            $env:LONG_RUN_INTEGRATION_VALUE = 'preserved'
            @"
@{
    cwd = (Get-Location).Path
    value = `$env:LONG_RUN_INTEGRATION_VALUE
} | ConvertTo-Json -Compress |
    Set-Content -LiteralPath '$($captureFile.Replace("'", "''"))'
Write-Output 'INTEGRATION_BASIC_OUTPUT'
exit 23
"@ | Set-Content -LiteralPath $commandFile -Encoding utf8

            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $commandFile -RemoveCommandFile `
                -WorkingDirectory $root -Session $session `
                -RemoteMode Never -NoViewer -PsmuxPath $psmux 2>&1

            $LASTEXITCODE | Should Be 23
            ($output -join "`n") | Should Match 'INTEGRATION_BASIC_OUTPUT'
            $capture = Get-Content -LiteralPath $captureFile -Raw |
                ConvertFrom-Json
            $capture.cwd | Should Be $root
            $capture.value | Should Be 'preserved'
            (Test-Path -LiteralPath $commandFile) | Should Be $false
            (Test-Path -LiteralPath $stateDir) | Should Be $false
            (Test-LongRunIntegrationSession $psmux $session) | Should Be $false
        } finally {
            $env:LONG_RUN_INTEGRATION_VALUE = $savedValue
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'replaces a completed command with a bounded same-name output viewer' `
        -Skip:(-not $runCore) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-retained'
        $commandFile = Join-Path $root 'command.ps1'
        $stateDir = Get-LongRunSessionStatePath (
            Join-Path $env:TEMP 'long-run') $session
        $savedLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = Join-Path $root 'local-app-data'
            @'
Write-Output 'RETAINED_FIRST_MARKER'
Write-Output 'RETAINED_LAST_MARKER'
exit 23
'@ | Set-Content -LiteralPath $commandFile -Encoding utf8

            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $commandFile -RemoveCommandFile `
                -WorkingDirectory $root -Session $session `
                -RemoteMode Never -NoViewer -PsmuxPath $psmux `
                -CompletedSessionTtlSeconds 3 2>&1

            $LASTEXITCODE | Should Be 23
            ($output -join "`n") | Should Match 'RETAINED_FIRST_MARKER'
            (Test-Path -LiteralPath $commandFile) | Should Be $false
            (Test-Path -LiteralPath $stateDir) | Should Be $false
            (Test-LongRunIntegrationSession $psmux $session) | Should Be $true

            $metadata = & $psmux list-sessions -F (
                '#{session_name}|#{@long-run-state}|' +
                '#{@long-run-exit-code}|#{@long-run-expires-at}') |
                Where-Object { $_ -like "$session|*" } |
                Select-Object -First 1
            $metadata | Should Match (
                "^$([regex]::Escape($session))\|completed\|23\|")
            $pane = & $psmux capture-pane -p -t $session -S -
            ($pane -join "`n") | Should Match 'Completed command output'
            ($pane -join "`n") | Should Match 'RETAINED_FIRST_MARKER'
            ($pane -join "`n") | Should Match 'RETAINED_LAST_MARKER'
            $paneState = & $psmux list-panes -t $session -F (
                '#{pane_dead}|#{pane_dead_status}|#{pane_pid}')
            $paneState | Should Match '^1\|0\|'
            $retainedPid = [int](($paneState -split '\|', 3)[2])
            (Get-Process -Id $retainedPid -ErrorAction SilentlyContinue) |
                Should BeNullOrEmpty

            $archiveRoot = Join-Path $env:LOCALAPPDATA 'long-run\completed'
            @(Get-ChildItem -LiteralPath $archiveRoot -Directory).Count |
                Should Be 1
            Stop-LongRunIntegrationSession $psmux $session
            (Wait-LongRunIntegrationCondition {
                -not (Test-LongRunIntegrationSession $psmux $session)
            } 5) | Should Be $true
            (Wait-LongRunIntegrationCondition {
                -not (Test-Path -LiteralPath $archiveRoot) -or
                @(Get-ChildItem -LiteralPath $archiveRoot -Directory `
                        -ErrorAction SilentlyContinue).Count -eq 0
            } 5) | Should Be $true
        } finally {
            $env:LOCALAPPDATA = $savedLocalAppData
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'preserves the child exit code when completed-output publication fails' `
        -Skip:(-not $runCore) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-retention-failure'
        $commandFile = Join-Path $root 'command.ps1'
        $localAppData = Join-Path $root 'local-app-data'
        $logPath = Join-Path $root 'retention-failure-events.jsonl'
        $savedLocalAppData = $env:LOCALAPPDATA
        $savedLogPath = $env:LONG_RUN_LOG_PATH
        $archiveMutex = [Threading.Mutex]::new(
            $false,
            'Local\LongRunCompletedSessionArchive')
        $archiveLocked = $false
        try {
            New-Item -ItemType Directory -Path $localAppData -Force |
                Out-Null
            Set-Content -LiteralPath $commandFile `
                -Value "Write-Output 'RETENTION_FAILURE_MARKER'; exit 31"
            $env:LOCALAPPDATA = $localAppData
            $env:LONG_RUN_LOG_PATH = $logPath
            $archiveLocked = $archiveMutex.WaitOne()

            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $commandFile -RemoveCommandFile `
                -WorkingDirectory $root -Session $session `
                -RemoteMode Never -NoViewer -PsmuxPath $psmux `
                -CompletedSessionTtlSeconds 60 2>&1

            $LASTEXITCODE | Should Be 31
            ($output -join "`n") | Should Match 'RETENTION_FAILURE_MARKER'
            (Test-LongRunIntegrationSession $psmux $session) | Should Be $false
            $event = Get-Content -LiteralPath $logPath |
                ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object event -EQ 'completed-retention-failed' |
                Select-Object -Last 1
            $event | Should Not BeNullOrEmpty
            $event.level | Should Be 'warning'
        } finally {
            if ($archiveLocked) {
                $archiveMutex.ReleaseMutex()
            }
            $archiveMutex.Dispose()
            $env:LOCALAPPDATA = $savedLocalAppData
            $env:LONG_RUN_LOG_PATH = $savedLogPath
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'can reuse a retained session name when retention is disabled' `
        -Skip:(-not $runCore) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-reuse'
        $firstCommand = Join-Path $root 'first.ps1'
        $secondCommand = Join-Path $root 'second.ps1'
        $savedLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = Join-Path $root 'local-app-data'
            Set-Content -LiteralPath $firstCommand `
                -Value "Write-Output 'FIRST_RETAINED'"
            $null = & pwsh -NoProfile -File $startScript `
                -CommandFile $firstCommand `
                -WorkingDirectory $root -Session $session `
                -RemoteMode Never -NoViewer -PsmuxPath $psmux `
                -CompletedSessionTtlSeconds 60
            $LASTEXITCODE | Should Be 0
            (Test-LongRunIntegrationSession $psmux $session) | Should Be $true

            Set-Content -LiteralPath $secondCommand `
                -Value "Write-Output 'SECOND_WITHOUT_RETENTION'"
            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $secondCommand `
                -WorkingDirectory $root -Session $session `
                -RemoteMode Never -NoViewer -PsmuxPath $psmux `
                -CompletedSessionTtlSeconds 0 2>&1
            $LASTEXITCODE | Should Be 0
            ($output -join "`n") | Should Match 'SECOND_WITHOUT_RETENTION'
            (Test-LongRunIntegrationSession $psmux $session) | Should Be $false
            $archiveRoot = Join-Path $env:LOCALAPPDATA 'long-run\completed'
            @(Get-ChildItem -LiteralPath $archiveRoot -Directory `
                    -ErrorAction SilentlyContinue).Count | Should Be 0
        } finally {
            $env:LOCALAPPDATA = $savedLocalAppData
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'accepts stdin from a second real psmux client' -Skip:(-not $runCore) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-stdin'
        $commandFile = Join-Path $root 'command.ps1'
        $resultFile = Join-Path $root 'input.txt'
        $stdoutPath = Join-Path $root 'owner.out.log'
        $stderrPath = Join-Path $root 'owner.err.log'
        $owner = $null
        $client = $null
        try {
            @"
`$line = [Console]::ReadLine()
[IO.File]::WriteAllText(
    '$($resultFile.Replace("'", "''"))',
    `$line,
    [Text.UTF8Encoding]::new(`$false))
Write-Output "READ:`$line"
"@ | Set-Content -LiteralPath $commandFile -Encoding utf8
            $launcher = New-LongRunLauncher $root $commandFile $session $psmux
            $owner = Start-LongRunIntegrationProcess `
                $launcher $stdoutPath $stderrPath
            (Wait-LongRunIntegrationCondition {
                Test-LongRunIntegrationSession $psmux $session
            }) | Should Be $true

            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $psmux
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment['PSMUX_PIPE_VT'] = '1'
            foreach ($argument in @('attach-session', '-t', $session)) {
                [void]$startInfo.ArgumentList.Add($argument)
            }
            $client = [Diagnostics.Process]::new()
            $client.StartInfo = $startInfo
            $client.Start() | Should Be $true
            Start-Sleep -Milliseconds 500
            $client.StandardInput.WriteLine('secondary-input-42')
            $client.StandardInput.Flush()

            (Wait-LongRunIntegrationCondition {
                Test-Path -LiteralPath $resultFile
            }) | Should Be $true
            (Get-Content -LiteralPath $resultFile -Raw) |
                Should Be 'secondary-input-42'
            (Wait-LongRunIntegrationCondition { $owner.HasExited }) |
                Should Be $true
            $owner.ExitCode | Should Be 0
        } finally {
            if ($client -and -not $client.HasExited) {
                Stop-LongRunIntegrationProcess $client
            }
            Stop-LongRunIntegrationProcess $owner
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'preserves semantic terminal output across stdout and stderr' `
        -Skip:(-not $runCore) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-output'
        $commandFile = Join-Path $root 'command.ps1'
        try {
            @'
[Console]::Out.WriteLine('INTEGRATION_STDOUT')
[Console]::Error.WriteLine('INTEGRATION_STDERR')
Write-Output 'INTEGRATION_UNICODE_snowman_☃'
Write-Host "$([char]27)[31mINTEGRATION_ANSI$([char]27)[0m"
Write-Progress -Activity 'INTEGRATION_PROGRESS' -PercentComplete 50
Write-Progress -Activity 'INTEGRATION_PROGRESS' -Completed
'@ | Set-Content -LiteralPath $commandFile -Encoding utf8

            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $commandFile -WorkingDirectory $root `
                -Session $session -RemoteMode Never -NoViewer `
                -PsmuxPath $psmux 2>&1
            $LASTEXITCODE | Should Be 0
            $text = $output -join "`n"
            $text | Should Match 'INTEGRATION_STDOUT'
            $text | Should Match 'INTEGRATION_STDERR'
            $text | Should Match 'INTEGRATION_UNICODE_snowman_☃'
            $text | Should Match 'INTEGRATION_ANSI'
        } finally {
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'removes the pane and state after abrupt owner death' `
        -Skip:(-not $runCore) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-owner'
        $commandFile = Join-Path $root 'command.ps1'
        $childPidFile = Join-Path $root 'child.pid'
        $stdoutPath = Join-Path $root 'owner.out.log'
        $stderrPath = Join-Path $root 'owner.err.log'
        $stateDir = Get-LongRunSessionStatePath (
            Join-Path $env:TEMP 'long-run') $session
        $owner = $null
        try {
            @"
[IO.File]::WriteAllText(
    '$($childPidFile.Replace("'", "''"))',
    [string]`$PID)
while (`$true) { Start-Sleep -Seconds 1 }
"@ | Set-Content -LiteralPath $commandFile -Encoding utf8
            $launcher = New-LongRunLauncher $root $commandFile $session $psmux
            $owner = Start-LongRunIntegrationProcess `
                $launcher $stdoutPath $stderrPath
            (Wait-LongRunIntegrationCondition {
                (Test-LongRunIntegrationSession $psmux $session) -and
                (Test-Path -LiteralPath $childPidFile) -and
                (Test-Path -LiteralPath $stateDir)
            }) | Should Be $true
            $childPid = [int](Get-Content -LiteralPath $childPidFile -Raw)

            Stop-Process -Id $owner.Id -Force
            [void]$owner.WaitForExit(5000)
            (Wait-LongRunIntegrationCondition {
                -not (Test-LongRunIntegrationSession $psmux $session) -and
                -not (Test-Path -LiteralPath $stateDir)
            } 20) | Should Be $true
            (Get-Process -Id $childPid -ErrorAction SilentlyContinue) |
                Should BeNullOrEmpty
        } finally {
            Stop-LongRunIntegrationProcess $owner
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'runs concurrent attached commands without session collisions' `
        -Skip:(-not $runCore) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $processes = @()
        $sessions = @(
            (New-LongRunIntegrationSession 'lr-int-concurrent'),
            (New-LongRunIntegrationSession 'lr-int-concurrent'))
        try {
            for ($index = 0; $index -lt $sessions.Count; $index++) {
                $commandFile = Join-Path $root "command-$index.ps1"
                $resultFile = Join-Path $root "result-$index.txt"
                "Start-Sleep -Seconds 2; Set-Content -LiteralPath " +
                    "'$($resultFile.Replace("'", "''"))' -Value '$index'" |
                    Set-Content -LiteralPath $commandFile -Encoding utf8
                $launcher = New-LongRunLauncher `
                    $root $commandFile $sessions[$index] $psmux
                $processes += Start-LongRunIntegrationProcess `
                    $launcher `
                    (Join-Path $root "owner-$index.out.log") `
                    (Join-Path $root "owner-$index.err.log")
            }

            (Wait-LongRunIntegrationCondition {
                (Test-LongRunIntegrationSession $psmux $sessions[0]) -and
                (Test-LongRunIntegrationSession $psmux $sessions[1])
            }) | Should Be $true
            foreach ($process in $processes) {
                (Wait-LongRunIntegrationCondition { $process.HasExited } 30) |
                    Should Be $true
                $process.ExitCode | Should Be 0
            }
            (Get-Content (Join-Path $root 'result-0.txt') -Raw).Trim() |
                Should Be '0'
            (Get-Content (Join-Path $root 'result-1.txt') -Raw).Trim() |
                Should Be '1'
        } finally {
            foreach ($process in $processes) {
                Stop-LongRunIntegrationProcess $process
            }
            foreach ($session in $sessions) {
                Stop-LongRunIntegrationSession $psmux $session
            }
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Long-run real browser transport integration' {
    It 'accepts stdin through gateway, ttyd, and WebSocket' `
        -Skip:(-not $runBrowser) {
        $root = New-LongRunIntegrationRoot
        $gatewayState = Join-Path $root 'gateway'
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-browser'
        $commandFile = Join-Path $root 'command.ps1'
        $resultFile = Join-Path $root 'input.txt'
        $owner = $null
        $gateway = $null
        try {
            foreach ($dependency in @('node', 'ttyd')) {
                (Get-Command $dependency -ErrorAction SilentlyContinue) |
                    Should Not BeNullOrEmpty
            }
            $gateway = & $startGateway -LocalOnly `
                -StateDirectory $gatewayState -PsmuxPath $psmux
            $gateway | Should Not BeNullOrEmpty
            $gateway.Port | Should BeGreaterThan 0
            $gateway.TerminalCapability | Should Not BeNullOrEmpty
            @"
`$line = [Console]::ReadLine()
[IO.File]::WriteAllText(
    '$($resultFile.Replace("'", "''"))',
    `$line,
    [Text.UTF8Encoding]::new(`$false))
"@ | Set-Content -LiteralPath $commandFile -Encoding utf8
            $launcher = New-LongRunLauncher $root $commandFile $session $psmux
            $owner = Start-LongRunIntegrationProcess `
                $launcher `
                (Join-Path $root 'owner.out.log') `
                (Join-Path $root 'owner.err.log')
            (Wait-LongRunIntegrationCondition {
                Test-LongRunIntegrationSession $psmux $session
            }) | Should Be $true

            $encodedSession = [uri]::EscapeDataString($session)
            $encodedCapability = [uri]::EscapeDataString(
                $gateway.TerminalCapability)
            $webSocketUrl =
                "ws://127.0.0.1:$($gateway.Port)/tmux/session/" +
                "$encodedSession/ws?accessToken=$encodedCapability"
            $nodeOutput = @(
                & node $sendTtydInput $webSocketUrl 'browser-input-42' 2>&1)
            $nodeExitCode = $LASTEXITCODE
            if ($nodeExitCode -ne 0) {
                $diagnostics = @(Get-ChildItem -LiteralPath $gatewayState `
                    -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object Name -Match '\.(?:out|err)\.log$' |
                    ForEach-Object {
                        "$($_.Name): " +
                        ((Get-Content -LiteralPath $_.FullName -Tail 20) -join "`n")
                    })
                throw "WebSocket helper failed ($nodeExitCode): " +
                    "$($nodeOutput -join "`n")`n$($diagnostics -join "`n")"
            }
            (Wait-LongRunIntegrationCondition {
                Test-Path -LiteralPath $resultFile
            } 20) | Should Be $true
            (Get-Content -LiteralPath $resultFile -Raw) |
                Should Be 'browser-input-42'
        } finally {
            Stop-LongRunIntegrationProcess $owner
            Stop-LongRunIntegrationSession $psmux $session
            & $stopGateway -StateDirectory $gatewayState
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Long-run real local viewer integration' {
    It 'opens a second attached client for a long command' -Skip:(-not $runUi) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-viewer'
        $commandFile = Join-Path $root 'command.ps1'
        $owner = $null
        try {
            'Start-Sleep -Seconds 8' |
                Set-Content -LiteralPath $commandFile -Encoding utf8
            $launcher = New-LongRunLauncher `
                $root $commandFile $session $psmux -OpenViewer
            $owner = Start-LongRunIntegrationProcess `
                $launcher `
                (Join-Path $root 'owner.out.log') `
                (Join-Path $root 'owner.err.log')
            (Wait-LongRunIntegrationCondition {
                $clients = @(& $psmux list-clients 2>$null)
                @($clients | Where-Object { $_ }).Count -ge 2
            } 10) | Should Be $true
            (Wait-LongRunIntegrationCondition { $owner.HasExited } 15) |
                Should Be $true
            $owner.ExitCode | Should Be 0
        } finally {
            Stop-LongRunIntegrationProcess $owner
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Long-run real Copilot plugin integration' {
    It 'loads only through plugin-dir and exercises wrapping and bypasses' `
        -Skip:(-not $runCopilot) {
        $root = New-LongRunIntegrationRoot
        $copilotHome = Join-Path $root 'copilot-home'
        $workspace = Join-Path $root 'workspace'
        $logPath = Join-Path $root 'events.jsonl'
        New-Item -ItemType Directory -Path $copilotHome, $workspace | Out-Null
        $savedHome = $env:COPILOT_HOME
        $savedLog = $env:LONG_RUN_LOG_PATH
        $dragonNames = @(
            'DRAGON_PORT',
            'DRAGON_INSTANCE',
            'DRAGON_REMOTE',
            'DRAGON_SIDE_BY_SIDE',
            'DRAGON-SERVER')
        $savedDragon = @{}
        try {
            (Get-Command copilot -ErrorAction SilentlyContinue) |
                Should Not BeNullOrEmpty
            $env:COPILOT_HOME = $copilotHome
            $env:LONG_RUN_LOG_PATH = $logPath
            foreach ($name in $dragonNames) {
                $savedDragon[$name] =
                    [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, $null, 'Process')
            }

            $discovery = @(& copilot --plugin-dir $pluginRoot plugin list 2>&1)
            $LASTEXITCODE | Should Be 0
            ($discovery -join "`n") | Should Match (
                'long-run \(v' + [regex]::Escape($pluginVersion) + '\)')

            $prompt = @'
Use the powershell tool exactly four times, synchronously, in this order:
1. Write-Output 'COPILOT_LONG_RUN_WRAPPED'
2. [pscustomobject]@{ value = 'COPILOT_LONG_RUN_JSON' } | ConvertTo-Json -Compress
3. $env:COPILOT_PSMUX = '0'; Write-Output 'COPILOT_LONG_RUN_OPTOUT'
4. psmux -V
Do not use any other tools. After all four calls, answer only: done
'@
            $output = @(
                & copilot --plugin-dir $pluginRoot -C $workspace `
                    --no-remote --allow-all-tools -s -p $prompt 2>&1)
            $LASTEXITCODE | Should Be 0
            ($output -join "`n") | Should Match '(?i)done'

            $events = @(Get-Content -LiteralPath $logPath |
                ForEach-Object { $_ | ConvertFrom-Json })
            @($events | Where-Object event -EQ 'wrapped').Count |
                Should BeGreaterThan 0
            @($events | Where-Object {
                $_.event -eq 'skipped' -and $_.reason -eq 'exact-output'
            }).Count | Should BeGreaterThan 0
            @($events | Where-Object {
                $_.event -eq 'skipped' -and $_.reason -eq 'explicit-opt-out'
            }).Count | Should BeGreaterThan 0
            @($events | Where-Object {
                $_.event -eq 'skipped' -and $_.reason -eq 'psmux-command'
            }).Count | Should BeGreaterThan 0

            $env:DRAGON_REMOTE = '1'
            $remotePrompt = @'
Use the powershell tool exactly once to run:
Start-Sleep -Milliseconds 200; Write-Output 'COPILOT_LONG_RUN_REMOTE_CONTEXT'
Then summarize the result for the user.
'@
            $remoteOutput = @(
                & copilot --plugin-dir $pluginRoot -C $workspace `
                    --no-remote --allow-all-tools -s -p $remotePrompt 2>&1)
            $LASTEXITCODE | Should Be 0
            $remoteText = $remoteOutput -join "`n"
            ($remoteText -match 'COPILOT_LONG_RUN_REMOTE_CONTEXT') |
                Should Be $true
            ($remoteText -match 'https://[^\s]+/tmux/session/[^\s]+') |
                Should Be $true
            $env:DRAGON_REMOTE = $null

            $withoutPlugin = @(& copilot plugin list 2>&1)
            $LASTEXITCODE | Should Be 0
            ($withoutPlugin -join "`n") | Should Not Match 'long-run'
        } finally {
            $env:COPILOT_HOME = $savedHome
            $env:LONG_RUN_LOG_PATH = $savedLog
            foreach ($name in $dragonNames) {
                [Environment]::SetEnvironmentVariable(
                    $name, $savedDragon[$name], 'Process')
            }
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Long-run complete output integration' {
    It 'captures all 5000 output rows from the attached client' `
        -Skip:(-not $runCore) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-volume'
        $commandFile = Join-Path $root 'command.ps1'
        try {
            @'
Write-Output 'BULK_BEGIN'
1..5000 | ForEach-Object { 'ROW-{0:D4}' -f $_ }
Write-Output 'BULK_END'
'@ | Set-Content -LiteralPath $commandFile -Encoding utf8
            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $commandFile -WorkingDirectory $root `
                -Session $session -RemoteMode Never -NoViewer `
                -PsmuxPath $psmux 2>&1
            $LASTEXITCODE | Should Be 0
            $text = $output -join "`n"
            ([regex]::Matches($text, 'BULK_BEGIN')).Count | Should Be 1
            ([regex]::Matches($text, 'BULK_END')).Count | Should Be 1
            $rows = @([regex]::Matches($text, 'ROW-(\d{4})') |
                ForEach-Object { [int]$_.Groups[1].Value })
            $rows.Count | Should Be 5000
            ($rows -join ',') | Should Be ((1..5000) -join ',')
        } finally {
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Long-run known psmux limitations' {
    It 'interrupts the pane when psmux receives C-c' `
        -Skip:(-not $runKnownLimits) {
        $root = New-LongRunIntegrationRoot
        $psmux = Get-LongRunIntegrationPsmux
        $session = New-LongRunIntegrationSession 'lr-int-cancel'
        $commandFile = Join-Path $root 'command.ps1'
        $owner = $null
        try {
            'while ($true) { Start-Sleep -Seconds 1 }' |
                Set-Content -LiteralPath $commandFile -Encoding utf8
            $launcher = New-LongRunLauncher $root $commandFile $session $psmux
            $owner = Start-LongRunIntegrationProcess `
                $launcher `
                (Join-Path $root 'owner.out.log') `
                (Join-Path $root 'owner.err.log')
            (Wait-LongRunIntegrationCondition {
                Test-LongRunIntegrationSession $psmux $session
            }) | Should Be $true
            & $psmux send-keys -t $session C-c
            $LASTEXITCODE | Should Be 0
            (Wait-LongRunIntegrationCondition { $owner.HasExited } 5) |
                Should Be $true
        } finally {
            Stop-LongRunIntegrationProcess $owner
            Stop-LongRunIntegrationSession $psmux $session
            Remove-Item -LiteralPath $root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}
