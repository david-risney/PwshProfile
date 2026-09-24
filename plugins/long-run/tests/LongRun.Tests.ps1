$pluginRoot = Split-Path -Parent $PSScriptRoot
$scriptRoot = Join-Path $pluginRoot 'skills\long-run\scripts'
$startScript = Join-Path $scriptRoot 'Start-LongRun.ps1'
$watchScript = Join-Path $scriptRoot 'Watch-LongRunSession.ps1'
$hookScript = Join-Path $pluginRoot 'hooks\Invoke-LongRunHook.ps1'
$publishUrlScript = Join-Path $pluginRoot 'hooks\Publish-LongRunUrl.ps1'

function New-FakePsmux([string]$Directory) {
    $scriptPath = Join-Path $Directory 'fake-psmux.ps1'
    @'
$root = $env:TEST_PSMUX_ROOT
$active = Join-Path $root 'active'
$sessionFile = Join-Path $root 'session'
$log = Join-Path $root 'calls.jsonl'
$logMutex = [Threading.Mutex]::new(
    $false,
    'Local\LongRunFakePsmuxCalls-' + (Split-Path -Leaf $root))
$logLocked = $false
try {
    $logLocked = $logMutex.WaitOne([TimeSpan]::FromSeconds(5))
    if (-not $logLocked) { throw 'Timed out waiting to write the fake psmux call log.' }
    [System.IO.File]::AppendAllText(
        $log,
        (($args | ConvertTo-Json -Compress) + [Environment]::NewLine))
} finally {
    if ($logLocked) { $logMutex.ReleaseMutex() }
    $logMutex.Dispose()
}
switch ($args[0]) {
    'new-session' {
        $sessionName = $args[[Array]::IndexOf($args, '-s') + 1]
        Set-Content -LiteralPath $sessionFile -Value $sessionName -NoNewline
        New-Item -ItemType File -Path $active -Force | Out-Null
        $separator = [Array]::IndexOf($args, '--')
        if ($separator -lt 0) {
            $programIndex = [Array]::FindIndex(
                [string[]]$args,
                [Predicate[string]]{ param($value) $value -match '(?i)(?:^|[\\/])pwsh(?:\.exe)?$' })
            if ($programIndex -lt 0) { throw 'Could not locate the psmux child program.' }
            $separator = $programIndex - 1
        }
        $program = $args[$separator + 1]
        $programArgs = @($args[($separator + 2)..($args.Count - 1)])
        $savedPane = $env:PSMUX_PANE
        $savedSession = $env:PSMUX_SESSION
        try {
            $env:PSMUX_PANE = '%1'
            $env:PSMUX_SESSION = $sessionName
            & $program @programArgs
        } finally {
            $env:PSMUX_PANE = $savedPane
            $env:PSMUX_SESSION = $savedSession
        }
        Remove-Item -LiteralPath $active -Force -ErrorAction SilentlyContinue
        exit 0
    }
    'has-session' {
        if (Test-Path -LiteralPath $active) { exit 0 }
        exit 1
    }
    'list-sessions' {
        $listCountFile = Join-Path $root 'list-session-count'
        $listCount = if (Test-Path -LiteralPath $listCountFile) {
            1 + [int](Get-Content -LiteralPath $listCountFile -Raw)
        } else {
            1
        }
        Set-Content -LiteralPath $listCountFile -Value $listCount -NoNewline
        if ($env:TEST_PSMUX_HANG_LIST_CALL -and
            $listCount -eq [int]$env:TEST_PSMUX_HANG_LIST_CALL) {
            Start-Sleep -Seconds 60
        }
        if (Test-Path -LiteralPath $active) {
            "$(Get-Content -LiteralPath $sessionFile -Raw)`t1700000000`t`$1"
            exit 0
        }
        exit 1
    }
    'list-panes' {
        if (Test-Path -LiteralPath $active) {
            '%1'
            exit 0
        }
        exit 1
    }
    'kill-session' {
        New-Item -ItemType File -Path (Join-Path $root 'killed') -Force | Out-Null
        Remove-Item -LiteralPath $active -Force -ErrorAction SilentlyContinue
        exit 0
    }
    'pipe-pane' {
        if ($env:TEST_PSMUX_RECORDER_FAIL -eq '1') {
            $quoted = @([regex]::Matches(
                    [string]$args[-1],
                    '"((?:[^"]|"")*)"') | ForEach-Object {
                    $_.Groups[1].Value -replace '""', '"'
                })
            if ($quoted.Count -ge 5) {
                New-Item -ItemType File -LiteralPath $quoted[-2] -Force | Out-Null
                New-Item -ItemType File -LiteralPath $quoted[-1] -Force | Out-Null
                New-Item -ItemType File `
                    -Path (Join-Path $root 'recorder-failure-injected') `
                    -Force | Out-Null
            }
            exit 0
        }
        if ($env:TEST_PSMUX_PIPE_SUCCESS -eq '1') { exit 0 }
        exit 1
    }
    default { exit 0 }
}
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8
    $path = Join-Path $Directory 'fake-psmux.cmd'
    '@pwsh -NoProfile -File "%~dp0fake-psmux.ps1" %*' |
        Set-Content -LiteralPath $path -Encoding ascii
    return $path
}

function Invoke-Hook(
    [object]$ToolArgs,
    [hashtable]$Environment = @{},
    [switch]$SerializeToolArgs
) {
    $payloadToolArgs = if ($SerializeToolArgs) {
        $ToolArgs | ConvertTo-Json -Compress -Depth 10
    } else {
        $ToolArgs
    }
    $payload = @{
        sessionId = 'test-session'
        timestamp = 0
        cwd = (Resolve-Path -LiteralPath $TestDrive).Path
        toolName = 'powershell'
        toolArgs = $payloadToolArgs
    } | ConvertTo-Json -Compress -Depth 10

    $saved = @{}
    $pwsh = (Get-Command pwsh -CommandType Application).Source
    $isolatedEnvironment = @{
        COPILOT_PSMUX = $null
        COPILOT_AGENT_SESSION_ID = $null
        DRAGON_PORT = $null
        DRAGON_INSTANCE = $null
        DRAGON_REMOTE = $null
        DRAGON_SIDE_BY_SIDE = $null
        'DRAGON-SERVER' = $null
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $isolatedEnvironment[$entry.Key] = $entry.Value
    }
    try {
        $saved.COPILOT_PLUGIN_ROOT = $env:COPILOT_PLUGIN_ROOT
        $env:COPILOT_PLUGIN_ROOT = $pluginRoot
        foreach ($entry in $isolatedEnvironment.GetEnumerator()) {
            $saved[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
            [Environment]::SetEnvironmentVariable(
                $entry.Key,
                $(if ($null -eq $entry.Value) { $null } else { [string]$entry.Value }),
                'Process')
        }
        return ($payload | & $pwsh -NoProfile -File $hookScript | ConvertFrom-Json)
    } finally {
        foreach ($entry in $saved.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }
}

function Invoke-PublishUrlHook([string]$ToolOutput) {
    $payload = @{
        sessionId = 'test-session'
        timestamp = 0
        cwd = (Resolve-Path -LiteralPath $TestDrive).Path
        toolName = 'powershell'
        toolArgs = '{}'
        toolResult = @{
            textResultForLlm = $ToolOutput
            resultType = 'success'
            sessionLog = $ToolOutput
        }
    } | ConvertTo-Json -Compress -Depth 10

    $pwsh = (Get-Command pwsh -CommandType Application).Source
    return ($payload | & $pwsh -NoProfile -File $publishUrlScript |
        ConvertFrom-Json)
}

function Wait-Condition([scriptblock]$Condition, [int]$TimeoutSeconds = 10) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

Describe 'Long-run remote detection' {
    It 'configures noninteractive process launches without a native window' {
        . (Join-Path $scriptRoot 'LongRun.Common.ps1')
        $startInfo = [Diagnostics.ProcessStartInfo]::new()

        Initialize-LongRunHiddenProcessStartInfo $startInfo

        $startInfo.UseShellExecute | Should Be $false
        $startInfo.CreateNoWindow | Should Be $true
        $startup = New-LongRunHiddenProcessStartupInformation
        try {
            $startup.ShowWindow | Should Be 0
        } finally {
            $startup.Dispose()
        }
    }

    It 'uses Copilot workspace metadata without requiring Dragon environment variables' {
        . (Join-Path $scriptRoot 'LongRun.Common.ps1')
        $saved = @{
            COPILOT_HOME = $env:COPILOT_HOME
            COPILOT_AGENT_SESSION_ID = $env:COPILOT_AGENT_SESSION_ID
            DRAGON_PORT = $env:DRAGON_PORT
            DRAGON_INSTANCE = $env:DRAGON_INSTANCE
            DRAGON_REMOTE = $env:DRAGON_REMOTE
            DRAGON_SIDE_BY_SIDE = $env:DRAGON_SIDE_BY_SIDE
            'DRAGON-SERVER' = ${env:DRAGON-SERVER}
        }
        try {
            $env:COPILOT_HOME = Join-Path $TestDrive 'copilot-home'
            $env:COPILOT_AGENT_SESSION_ID = 'workspace-test'
            $env:DRAGON_PORT = $null
            $env:DRAGON_INSTANCE = $null
            $env:DRAGON_REMOTE = $null
            $env:DRAGON_SIDE_BY_SIDE = $null
            ${env:DRAGON-SERVER} = $null
            $workspaceDirectory = Join-Path $env:COPILOT_HOME `
                'session-state\workspace-test'
            New-Item -ItemType Directory -Force -Path $workspaceDirectory |
                Out-Null
            $workspaceFile = Join-Path $workspaceDirectory 'workspace.yaml'

            "client_name: dragon/vscode`nremote_steerable: false" |
                Set-Content -LiteralPath $workspaceFile
            Test-LongRunRemoteSession | Should Be $true

            "client_name: copilot-cli`nremote_steerable: true" |
                Set-Content -LiteralPath $workspaceFile
            Test-LongRunRemoteSession | Should Be $true

            "client_name: copilot-cli`nremote_steerable: false" |
                Set-Content -LiteralPath $workspaceFile
            Test-LongRunRemoteSession | Should Be $false

            Remove-Item -LiteralPath $workspaceFile
            Test-LongRunRemoteSession | Should Be $false
        } finally {
            foreach ($entry in $saved.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable(
                    $entry.Key,
                    $entry.Value,
                    'Process')
            }
        }
    }
}

Describe 'Start-LongRun' {
    BeforeEach {
        $env:LONG_RUN_COMPLETED_SESSION_TTL_SECONDS = '0'
        $env:TEST_PSMUX_ROOT = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $env:TEST_PSMUX_ROOT | Out-Null
        $fakePsmux = New-FakePsmux $env:TEST_PSMUX_ROOT
    }

    AfterEach {
        Remove-Item Env:LONG_RUN_COMPLETED_SESSION_TTL_SECONDS `
            -ErrorAction SilentlyContinue
    }

    It 'runs attached, preserves cwd and environment, returns the child code, and cleans up' {
        $session = 'test-attached-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $commandFile = Join-Path $TestDrive 'original command.ps1'
        $captureFile = Join-Path $TestDrive 'capture.json'
        $env:LONG_RUN_TEST_VALUE = 'preserved-value'
        @"
@{ cwd = (Get-Location).Path; value = `$env:LONG_RUN_TEST_VALUE; pipeVt = `$env:PSMUX_PIPE_VT } |
    ConvertTo-Json -Compress |
    Set-Content -LiteralPath '$($captureFile -replace "'", "''")'
Write-Output 'transparent-output'
exit 23
"@ | Set-Content -LiteralPath $commandFile -Encoding utf8

        $output = & pwsh -NoProfile -File $startScript `
            -CommandFile $commandFile -RemoveCommandFile `
            -WorkingDirectory $TestDrive -Session $session `
            -NoViewer -RemoteMode Never -PsmuxPath $fakePsmux 2>&1
        $LASTEXITCODE | Should Be 23
        ($output -join "`n") | Should Match 'transparent-output'

        $capture = Get-Content -LiteralPath $captureFile -Raw | ConvertFrom-Json
        $capture.cwd | Should Be (Resolve-Path -LiteralPath $TestDrive).Path
        $capture.value | Should Be 'preserved-value'
        $capture.pipeVt | Should BeNullOrEmpty
        (Test-Path -LiteralPath $commandFile) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $env:TEMP "long-run\$session")) | Should Be $false

        $newSession = @(Get-Content -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate } |
            Where-Object { $_[0] -eq 'new-session' } |
            Select-Object -First 1)[0]
        $newSession | Should Not BeNullOrEmpty
        ($newSession -contains '-d') | Should Be $false
        ($newSession -contains '-s') | Should Be $true
        ($newSession -contains $session) | Should Be $true
        $statusOption = @(Get-Content -LiteralPath (
                Join-Path $env:TEST_PSMUX_ROOT 'calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate } |
            Where-Object {
                $_[0] -eq 'set-option' -and
                $_[-2] -eq 'status' -and
                $_[-1] -eq 'off'
            } |
            Select-Object -First 1)[0]
        $statusOption | Should Not BeNullOrEmpty
        $pipePane = @(Get-Content -LiteralPath (
                Join-Path $env:TEST_PSMUX_ROOT 'calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate } |
            Where-Object { $_[0] -eq 'pipe-pane' } |
            Select-Object -First 1)[0]
        $pipePane | Should Not BeNullOrEmpty
        [string]$pipePane[-1] | Should Match '^pwsh\.exe '
    }

    It 'continues an automatic remote run when gateway startup fails' {
        $session = 'gateway-fallback'
        $commandFile = Join-Path $TestDrive 'gateway-fallback.ps1'
        $gatewayScript = Join-Path $TestDrive 'failing-gateway.ps1'
        Set-Content -LiteralPath $commandFile -Value "Write-Output 'still-ran'; exit 17"
        Set-Content -LiteralPath $gatewayScript -Value "throw 'ttyd was not found'"
        $savedRemote = $env:DRAGON_REMOTE
        try {
            $env:DRAGON_REMOTE = '1'
            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $commandFile -WorkingDirectory $TestDrive `
                -Session $session -NoViewer -RemoteMode Auto `
                -PsmuxPath $fakePsmux -GatewayScript $gatewayScript 3>&1
            $LASTEXITCODE | Should Be 17
            ($output -join "`n") | Should Match 'still-ran'
            ($output -join "`n") | Should Match 'continuing without it'
        } finally {
            $env:DRAGON_REMOTE = $savedRemote
        }
    }

    It 'releases the child when session discovery times out' {
        $session = 'capture-session-timeout'
        $commandFile = Join-Path $TestDrive 'capture-session-timeout.ps1'
        Set-Content -LiteralPath $commandFile `
            -Value "Write-Output 'session-timeout-fallback'; exit 0"
        $saved = $env:TEST_PSMUX_HANG_LIST_CALL
        try {
            $env:TEST_PSMUX_HANG_LIST_CALL = '2'
            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $commandFile -WorkingDirectory $TestDrive `
                -Session $session -NoViewer -RemoteMode Never `
                -CaptureSetupTimeoutSeconds 1 -PsmuxPath $fakePsmux 2>&1
            $LASTEXITCODE | Should Be 0
            ($output -join "`n") | Should Match 'session-timeout-fallback'
        } finally {
            $env:TEST_PSMUX_HANG_LIST_CALL = $saved
        }
    }

    It 'falls back when the transcript recorder never becomes ready' {
        $session = 'capture-recorder-timeout'
        $commandFile = Join-Path $TestDrive 'capture-recorder-timeout.ps1'
        Set-Content -LiteralPath $commandFile `
            -Value "Write-Output 'recorder-timeout-fallback'; exit 0"
        $saved = $env:TEST_PSMUX_PIPE_SUCCESS
        try {
            $env:TEST_PSMUX_PIPE_SUCCESS = '1'
            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $commandFile -WorkingDirectory $TestDrive `
                -Session $session -NoViewer -RemoteMode Never `
                -CaptureSetupTimeoutSeconds 1 -PsmuxPath $fakePsmux 2>&1
            $LASTEXITCODE | Should Be 0
            ($output -join "`n") | Should Match 'recorder-timeout-fallback'
        } finally {
            $env:TEST_PSMUX_PIPE_SUCCESS = $saved
        }
    }

    It 'returns the child code when the transcript recorder fails' {
        $session = 'capture-recorder-failure'
        $commandFile = Join-Path $TestDrive 'capture-recorder-failure.ps1'
        Set-Content -LiteralPath $commandFile `
            -Value "Write-Output 'recorder-failure-fallback'; exit 29"
        $saved = $env:TEST_PSMUX_RECORDER_FAIL
        try {
            $env:TEST_PSMUX_RECORDER_FAIL = '1'
            $output = & pwsh -NoProfile -File $startScript `
                -CommandFile $commandFile -WorkingDirectory $TestDrive `
                -Session $session -NoViewer -RemoteMode Never `
                -CaptureSetupTimeoutSeconds 1 -PsmuxPath $fakePsmux 2>&1
            $LASTEXITCODE | Should Be 29
            ($output -join "`n") | Should Match 'recorder-failure-fallback'
            (Test-Path -LiteralPath (
                    Join-Path $env:TEST_PSMUX_ROOT 'recorder-failure-injected')) |
                Should Be $true
        } finally {
            $env:TEST_PSMUX_RECORDER_FAIL = $saved
        }
    }

    It 'publishes the remote URL before starting the synchronous command' {
        $session = 'remote-before-command'
        $commandFile = Join-Path $TestDrive 'remote-order.ps1'
        $gatewayScript = Join-Path $TestDrive 'fake-gateway.ps1'
        Set-Content -LiteralPath $commandFile -Value "Write-Output 'COMMAND_STARTED'; exit 0"
        @'
[pscustomobject]@{
    Url = 'https://example.devtunnels.ms/tmux/?accessToken=capability'
    BaseUrl = 'https://example.devtunnels.ms'
    TerminalCapability = 'capability'
}
'@ | Set-Content -LiteralPath $gatewayScript

        $output = & pwsh -NoProfile -File $startScript `
            -CommandFile $commandFile -WorkingDirectory $TestDrive `
            -Session $session -NoViewer -RemoteMode Always `
            -PsmuxPath $fakePsmux -GatewayScript $gatewayScript 2>&1

        $LASTEXITCODE | Should Be 0
        $lines = @($output | ForEach-Object { [string]$_ })
        $urlIndex = [Array]::FindIndex(
            [string[]]$lines,
            [Predicate[string]]{
                param($line)
                $line -match '^LONGRUN_REMOTE_URL='
            })
        $commandIndex = [Array]::IndexOf([string[]]$lines, 'COMMAND_STARTED')
        $urlIndex | Should BeGreaterThan -1
        $commandIndex | Should BeGreaterThan $urlIndex
        ($lines -join "`n") | Should Match "Long-running command session: $session"
    }

    It 'returns the psmux failure code when the child never starts' {
        $session = 'psmux-start-failure'
        $commandFile = Join-Path $TestDrive 'never-started.ps1'
        Set-Content -LiteralPath $commandFile -Value 'exit 0'
        $project = Join-Path $TestDrive 'failing-psmux'
        & dotnet new console --name failing-psmux --framework net8.0 `
            --no-restore --output $project | Out-Null
        @'
public static class Program {
    public static int Main(string[] args) => 1;
}
'@ | Set-Content -LiteralPath (Join-Path $project 'Program.cs') -Encoding utf8
        & dotnet build $project --configuration Release --nologo | Out-Null
        $LASTEXITCODE | Should Be 0
        $failingPsmux =
            Join-Path $project 'bin\Release\net8.0\failing-psmux.exe'

        $process = Start-Process -FilePath (Get-Command pwsh).Source `
            -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-File', "`"$startScript`"",
                '-CommandFile', "`"$commandFile`"",
                '-WorkingDirectory', "`"$TestDrive`"",
                '-Session', $session,
                '-NoViewer',
                '-RemoteMode', 'Never',
                '-PsmuxPath', "`"$failingPsmux`""
            )

        $process.ExitCode | Should Be 1
    }

    It 'kills an orphaned named session from the watcher' {
        New-Item -ItemType File -Path (Join-Path $env:TEST_PSMUX_ROOT 'active') | Out-Null
        Set-Content -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'session') `
            -Value 'orphan-test' -NoNewline
        $stateDir = Join-Path $TestDrive 'orphan-state'
        New-Item -ItemType Directory -Path $stateDir | Out-Null
        Set-Content -LiteralPath (Join-Path $stateDir 'owner-token') `
            -Value 'orphan-owner' -NoNewline
        $commandFile = Join-Path $TestDrive 'orphan-command.ps1'
        Set-Content -LiteralPath $commandFile -Value 'secret command'
        @{ commandFiles = @($commandFile) } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $stateDir 'cleanup.json')
        & pwsh -NoProfile -File $watchScript -OwnerPid 2147483647 `
            -OwnerStartTimeUtcTicks 1 -OwnerPath 'C:\missing-owner.exe' `
            -PsmuxPath $fakePsmux -Session 'orphan-test' `
            -ExpectedCreated 1700000000 -ExpectedId '$1' `
            -OwnerToken 'orphan-owner' `
            -StateDirectory $stateDir `
            -DelaySeconds 999 -NoViewer
        $LASTEXITCODE | Should Be 0
        (Test-Path -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'killed')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'active')) | Should Be $false
        (Test-Path -LiteralPath $stateDir) | Should Be $false
        (Test-Path -LiteralPath $commandFile) | Should Be $false
    }

    It 'keeps detached cleanup work alive after the owner process tree exits' {
        $commonScript = Join-Path $scriptRoot 'LongRun.Common.ps1'
        $readyFile = Join-Path $TestDrive 'detached-owner-ready'
        $survivedFile = Join-Path $TestDrive 'detached-watcher-survived'
        $parentScript = Join-Path $TestDrive 'detached-watcher-parent.ps1'
        $detachedCommand = (
            "Start-Sleep -Seconds 2; " +
            "[System.IO.File]::WriteAllText('$($survivedFile -replace "'", "''")', 'survived')")
        @"
. '$($commonScript -replace "'", "''")'
Start-LongRunDetachedPowerShell ``
    -Command '$($detachedCommand -replace "'", "''")' ``
    -Name 'survival-test'
[System.IO.File]::WriteAllText('$($readyFile -replace "'", "''")', 'ready')
Start-Sleep -Seconds 60
"@ | Set-Content -LiteralPath $parentScript -Encoding utf8

        $parent = Start-Process -FilePath (Get-Command pwsh).Source `
            -PassThru -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-File', "`"$parentScript`"")
        try {
            (Wait-Condition { Test-Path -LiteralPath $readyFile } 10) |
                Should Be $true
            $parent.Kill($true)
            $parent.WaitForExit(5000) | Should Be $true
            (Wait-Condition { Test-Path -LiteralPath $survivedFile } 10) |
                Should Be $true
        } finally {
            if (-not $parent.HasExited) { $parent.Kill($true) }
            $parent.Dispose()
        }
    }

    It 'waits for the named session to appear before monitoring it' {
        $watcher = Start-Process -FilePath (Get-Command pwsh).Source -PassThru `
            -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-File', "`"$watchScript`"",
                '-OwnerPid', [string]$PID,
                '-OwnerStartTimeUtcTicks',
                [string](Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks,
                '-OwnerPath', "`"$((Get-Process -Id $PID).Path)`"",
                '-PsmuxPath', "`"$fakePsmux`"",
                '-Session', 'startup-race-test',
                '-ExpectedCreated', '1700000000',
                '-ExpectedId', '$1',
                '-OwnerToken', 'startup-owner',
                '-StateDirectory', "`"$TestDrive`"",
                '-DelaySeconds', '999',
                '-SessionWarningSeconds', '1',
                '-NoViewer'
            )
        try {
            Start-Sleep -Milliseconds 1500
            $watcher.HasExited | Should Be $false
            New-Item -ItemType File `
                -Path (Join-Path $env:TEST_PSMUX_ROOT 'active') | Out-Null
            Set-Content -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'session') `
                -Value 'startup-race-test' -NoNewline
            Start-Sleep -Seconds 2
            $watcher.HasExited | Should Be $false
            Remove-Item -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'active')
            $watcher.WaitForExit(5000) | Should Be $true
        } finally {
            if (-not $watcher.HasExited) {
                $watcher.Kill($true)
            }
            $watcher.Dispose()
        }
    }

    It 'uses terminal context captured before detaching the watcher' {
        $session = 'viewer-context-test'
        New-Item -ItemType File `
            -Path (Join-Path $env:TEST_PSMUX_ROOT 'active') | Out-Null
        Set-Content -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'session') `
            -Value $session -NoNewline
        $stateDir = Join-Path $TestDrive 'viewer-context-state'
        New-Item -ItemType Directory -Path $stateDir | Out-Null
        Set-Content -LiteralPath (Join-Path $stateDir 'owner-token') `
            -Value 'viewer-owner' -NoNewline
        $viewerLog = Join-Path $TestDrive 'viewer-arguments.txt'
        $fakeWt = Join-Path $TestDrive 'fake-wt.cmd'
        "@echo %*>`"$viewerLog`"" |
            Set-Content -LiteralPath $fakeWt -Encoding ascii

        $watcher = Start-Process -FilePath (Get-Command pwsh).Source `
            -PassThru -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-File', "`"$watchScript`"",
                '-OwnerPid', [string]$PID,
                '-OwnerStartTimeUtcTicks',
                [string](Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks,
                '-OwnerPath', "`"$((Get-Process -Id $PID).Path)`"",
                '-PsmuxPath', "`"$fakePsmux`"",
                '-Session', $session,
                '-ExpectedCreated', '1700000000',
                '-ExpectedId', '$1',
                '-OwnerToken', 'viewer-owner',
                '-StateDirectory', "`"$stateDir`"",
                '-DelaySeconds', '0',
                '-WindowsTerminalSession', 'captured-session',
                '-WindowsTerminalPath', "`"$fakeWt`""
            )
        try {
            (Wait-Condition { Test-Path -LiteralPath $viewerLog } 10) |
                Should Be $true
            $arguments = Get-Content -LiteralPath $viewerLog -Raw
            $arguments | Should Match '-w 0 new-tab'
            $arguments | Should Match ([regex]::Escape($session))
            Remove-Item -LiteralPath (
                Join-Path $env:TEST_PSMUX_ROOT 'active') -Force
            $watcher.WaitForExit(5000) | Should Be $true
        } finally {
            if (-not $watcher.HasExited) { $watcher.Kill($true) }
            $watcher.Dispose()
        }
    }

    It 'does not kill a pre-existing session with the requested name' {
        $session = 'existing-session'
        New-Item -ItemType File -Path (Join-Path $env:TEST_PSMUX_ROOT 'active') | Out-Null
        Set-Content -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'session') `
            -Value $session -NoNewline
        $commandFile = Join-Path $TestDrive 'collision.ps1'
        Set-Content -LiteralPath $commandFile -Value 'exit 0'
        $stateDir = Join-Path $env:TEMP "long-run\$session"
        New-Item -ItemType Directory -Path $stateDir | Out-Null
        $marker = Join-Path $stateDir 'owned-by-other-run'
        Set-Content -LiteralPath $marker -Value 'keep'

        try {
            & pwsh -NoProfile -File $startScript -CommandFile $commandFile `
                -WorkingDirectory $TestDrive -Session $session `
                -NoViewer -RemoteMode Never -PsmuxPath $fakePsmux 2>$null

            $LASTEXITCODE | Should Not Be 0
            (Test-Path -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'active')) |
                Should Be $true
            (Test-Path -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'killed')) |
                Should Be $false
            (Test-Path -LiteralPath $marker) | Should Be $true
        } finally {
            Remove-Item -LiteralPath $stateDir -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'does not let a stale watcher delete replacement state' {
        New-Item -ItemType File -Path (Join-Path $env:TEST_PSMUX_ROOT 'active') | Out-Null
        Set-Content -LiteralPath (Join-Path $env:TEST_PSMUX_ROOT 'session') `
            -Value 'replacement-state' -NoNewline
        $stateDir = Join-Path $TestDrive 'replacement-state'
        New-Item -ItemType Directory -Path $stateDir | Out-Null
        $marker = Join-Path $stateDir 'replacement-marker'
        Set-Content -LiteralPath $marker -Value 'keep'
        Set-Content -LiteralPath (Join-Path $stateDir 'owner-token') `
            -Value 'new-owner' -NoNewline

        & pwsh -NoProfile -File $watchScript -OwnerPid 2147483647 `
            -OwnerStartTimeUtcTicks 1 -OwnerPath 'C:\missing-owner.exe' `
            -PsmuxPath $fakePsmux -Session 'replacement-state' `
            -ExpectedCreated 1700000000 -ExpectedId '$1' `
            -OwnerToken 'old-owner' -StateDirectory $stateDir `
            -DelaySeconds 999 -NoViewer

        $LASTEXITCODE | Should Be 0
        (Test-Path -LiteralPath $marker) | Should Be $true
    }

    It 'does not let owner cleanup delete replacement state' {
        $session = 'replaced-owner-state'
        $stateDir = Join-Path $env:TEMP "long-run\$session"
        $commandFile = Join-Path $TestDrive 'replace-owner-token.ps1'
        @"
[System.IO.File]::WriteAllText(
    '$((Join-Path $stateDir 'owner-token') -replace "'", "''")',
    'replacement-owner')
exit 0
"@ | Set-Content -LiteralPath $commandFile

        & pwsh -NoProfile -File $startScript -CommandFile $commandFile `
            -WorkingDirectory $TestDrive -Session $session `
            -NoViewer -RemoteMode Never -PsmuxPath $fakePsmux 2>$null

        $LASTEXITCODE | Should Be 0
        (Test-Path -LiteralPath $stateDir) | Should Be $true
        [System.IO.File]::ReadAllText((Join-Path $stateDir 'owner-token')) |
            Should Be 'replacement-owner'
        Remove-Item -LiteralPath $stateDir -Recurse -Force
    }

    It 'rejects dot-segment session names without deleting shared state' {
        $stateRoot = Join-Path $env:TEMP 'long-run'
        New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
        $marker = Join-Path $stateRoot 'shared-state-marker'
        Set-Content -LiteralPath $marker -Value 'keep'

        & pwsh -NoProfile -File $startScript -Command 'exit 0' `
            -WorkingDirectory $TestDrive -Session '..' `
            -NoViewer -RemoteMode Never -PsmuxPath $fakePsmux 2>$null

        $LASTEXITCODE | Should Not Be 0
        (Test-Path -LiteralPath $marker) | Should Be $true
        Remove-Item -LiteralPath $marker -Force
    }
}

Describe 'Invoke-LongRunHook' {
    It 'rewrites an eligible synchronous PowerShell call without losing tool arguments' {
        $result = Invoke-Hook @{
            command = "Write-Output 'quoted value'"
            description = 'Run a normal command'
            initial_wait = 120
            mode = 'sync'
        }

        $result.modifiedArgs.description | Should Be 'Run a normal command'
        $result.modifiedArgs.initial_wait | Should Be 120
        $result.modifiedArgs.mode | Should Be 'sync'
        $result.modifiedArgs.command | Should Match 'Start-LongRun\.ps1'
        $result.modifiedArgs.command | Should Match "-Session 'lr-write-output-quoted-value-[a-f0-9]{8}'"
        $result.modifiedArgs.command | Should Match '-RemoteMode Never'
        $result.modifiedArgs.command | Should Match '-NoViewer'
        $result.modifiedArgs.command | Should Match 'finally \{ Remove-Item'
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $result.modifiedArgs.command, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0

        $match = [regex]::Match($result.modifiedArgs.command, "-CommandFile '([^']+)'")
        $match.Success | Should Be $true
        $commandFileContent =
            [System.IO.File]::ReadAllText($match.Groups[1].Value)
        $commandFileContent | Should Match "Write-Output 'quoted value'"
        $commandFileContent | Should Not Match '\$global:LASTEXITCODE\s*='
        Remove-Item -LiteralPath $match.Groups[1].Value -Force
    }

    It 'rewrites Dragon-style serialized tool arguments without losing fields' {
        $result = Invoke-Hook @{
            command = "Write-Output 'serialized value'"
            description = 'Run a serialized command'
            initial_wait = 45
            mode = 'sync'
            shellId = 'dragon-hook-probe'
        } -SerializeToolArgs

        $result.modifiedArgs.description | Should Be 'Run a serialized command'
        $result.modifiedArgs.initial_wait | Should Be 45
        $result.modifiedArgs.shellId | Should Be 'dragon-hook-probe'
        $result.modifiedArgs.mode | Should Be 'sync'
        $result.modifiedArgs.command | Should Match 'Start-LongRun\.ps1'
        $match = [regex]::Match(
            $result.modifiedArgs.command,
            "-CommandFile '([^']+)'")
        $match.Success | Should Be $true
        [System.IO.File]::ReadAllText($match.Groups[1].Value) |
            Should Match "Write-Output 'serialized value'"
        Remove-Item -LiteralPath $match.Groups[1].Value -Force
    }

    It 'preserves a native command failure through the generated command file' {
        $result = Invoke-Hook @{
            command = "& `$env:ComSpec /d /c 'exit /b 7'"
            description = 'Return a native failure'
            mode = 'sync'
        }
        $match = [regex]::Match(
            $result.modifiedArgs.command,
            "-CommandFile '([^']+)'")
        $match.Success | Should Be $true
        $commandFile = $match.Groups[1].Value
        try {
            & pwsh -NoProfile -File $commandFile
            $LASTEXITCODE | Should Be 7
        } finally {
            Remove-Item -LiteralPath $commandFile -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'does not reuse a stale native exit code for a final PowerShell failure' {
        $missingPath = Join-Path $TestDrive 'missing-hook-path'
        $result = Invoke-Hook @{
            command = "& `$env:ComSpec /d /c 'exit /b 23'; Get-Item '$missingPath'"
            description = 'Return a PowerShell failure'
            mode = 'sync'
        }
        $match = [regex]::Match(
            $result.modifiedArgs.command,
            "-CommandFile '([^']+)'")
        $match.Success | Should Be $true
        $commandFile = $match.Groups[1].Value
        try {
            & pwsh -NoProfile -File $commandFile 2>$null
            $LASTEXITCODE | Should Be 1
        } finally {
            Remove-Item -LiteralPath $commandFile -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'returns one for an ignored final PowerShell error after a native failure' {
        $missingPath = Join-Path $TestDrive 'ignored-missing-hook-path'
        $result = Invoke-Hook @{
            command = "& `$env:ComSpec /d /c 'exit /b 23'; Get-Item '$missingPath' -ErrorAction Ignore"
            description = 'Return an ignored PowerShell failure'
            mode = 'sync'
        }
        $match = [regex]::Match(
            $result.modifiedArgs.command,
            "-CommandFile '([^']+)'")
        $match.Success | Should Be $true
        $commandFile = $match.Groups[1].Value
        try {
            & pwsh -NoProfile -File $commandFile
            $LASTEXITCODE | Should Be 1
        } finally {
            Remove-Item -LiteralPath $commandFile -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'does not wrap a branch-dependent terminal statement' {
        $result = Invoke-Hook @{
            command = "if (`$true) { & `$env:ComSpec /d /c 'exit /b 23' }"
            description = 'Run a branch-dependent command'
            mode = 'sync'
        }

        @($result.PSObject.Properties).Count | Should Be 0
    }

    It 'does not wrap a native command invoked through a runtime variable' {
        $result = Invoke-Hook @{
            command = "`$exe = `$env:ComSpec`n& `$exe /d /c 'exit /b 23'"
            description = 'Run a dynamic native command'
            mode = 'sync'
        }

        @($result.PSObject.Properties).Count | Should Be 0
    }

    It 'does not wrap native commands invoked through runtime expressions' {
        $cases = @(
            @{
                Command = "`$tool = Get-Command `$env:ComSpec`n& `$tool.Source /d /c 'exit /b 26'"
                ExitCode = 26
            },
            @{
                Command = "`$commands = @(`$env:ComSpec)`n& `$commands[0] /d /c 'exit /b 27'"
                ExitCode = 27
            },
            @{
                Command = "& (Get-Command `$env:ComSpec) /d /c 'exit /b 28'"
                ExitCode = 28
            }
        )
        foreach ($case in $cases) {
            $result = Invoke-Hook @{
                command = $case.Command
                description = 'Run a dynamic native command'
                mode = 'sync'
            }
            @($result.PSObject.Properties).Count | Should Be 0
        }
    }

    It 'does not expose wrapper state to the original command' {
        $result = Invoke-Hook @{
            command = "'LAST=' + [string]`$LASTEXITCODE; " +
                "'BREAKPOINTS=' + @(Get-PSBreakpoint).Count"
            description = 'Inspect wrapper state'
            mode = 'sync'
        }
        $match = [regex]::Match(
            $result.modifiedArgs.command,
            "-CommandFile '([^']+)'")
        $match.Success | Should Be $true
        $commandFile = $match.Groups[1].Value
        try {
            $output = & pwsh -NoProfile -File $commandFile
            $LASTEXITCODE | Should Be 0
            ($output -join "`n") | Should Match 'LAST=\s*\r?\n'
            ($output -join "`n") | Should Match 'BREAKPOINTS=0'
        } finally {
            Remove-Item -LiteralPath $commandFile -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'fails open for malformed serialized tool arguments' {
        $logPath = Join-Path $TestDrive 'malformed-hook-events.jsonl'

        $result = Invoke-Hook '{"command":' @{
            LONG_RUN_LOG_PATH = $logPath
        }

        @($result.PSObject.Properties).Count | Should Be 0
        $event = Get-Content -LiteralPath $logPath |
            Select-Object -Last 1 |
            ConvertFrom-Json
        $event.component | Should Be 'hook'
        $event.event | Should Be 'skipped'
        $event.reason | Should Be 'malformed-serialized-tool-arguments'
    }

    It 'forces remote gateway mode for Dragon before the command starts' {
        $result = Invoke-Hook @{
            command = 'Start-Sleep 30'
            description = 'Run a normal command'
            mode = 'sync'
        } @{ DRAGON_REMOTE = '1' }

        $result.modifiedArgs.command | Should Match "-Session 'lr-start-sleep-[a-f0-9]{8}'"
        $result.modifiedArgs.command | Should Match '-RemoteMode Always'
        $match = [regex]::Match(
            $result.modifiedArgs.command,
            "-CommandFile '([^']+)'")
        Remove-Item -LiteralPath $match.Groups[1].Value -Force
    }

    $skipCases = @(
        @{ name = 'a psmux command'; args = @{ command = 'psmux list-sessions'; mode = 'sync' }; env = @{} },
        @{ name = 'a quoted psmux path'; args = @{ command = '& ''C:\Program Files\psmux\psmux.exe'' attach-session'; mode = 'sync' }; env = @{} },
        @{ name = 'a relative psmux path'; args = @{ command = '.\tools\pmux.exe list-sessions'; mode = 'sync' }; env = @{} },
        @{ name = 'a psmux path variable'; args = @{ command = '& $PsmuxPath attach-session'; mode = 'sync' }; env = @{} },
        @{ name = 'a command with parse errors'; args = @{ command = 'if ('; mode = 'sync' }; env = @{} },
        @{ name = 'an async command'; args = @{ command = 'Start-Sleep 20'; mode = 'async' }; env = @{} },
        @{ name = 'a detached command'; args = @{ command = 'Start-Sleep 20'; mode = 'async'; detach = $true }; env = @{} },
        @{ name = 'machine-readable output'; args = @{ command = 'gh pr view --json title'; mode = 'sync' }; env = @{} },
        @{ name = 'an exact-output description'; args = @{ command = 'Get-Content artifact.bin'; description = 'Return the exact bytes'; mode = 'sync' }; env = @{} },
        @{ name = 'an AsByteStream command'; args = @{ command = 'Get-Content artifact.bin -AsByteStream'; mode = 'sync' }; env = @{} },
        @{ name = 'an Encoding Byte command'; args = @{ command = 'Get-Content artifact.bin -Encoding Byte'; mode = 'sync' }; env = @{} },
        @{ name = 'a command opt-out'; args = @{ command = '$env:COPILOT_PSMUX = ''0''; Write-Output x'; mode = 'sync' }; env = @{} },
        @{ name = 'an environment opt-out'; args = @{ command = 'Write-Output x'; mode = 'sync' }; env = @{ COPILOT_PSMUX = '0' } },
        @{ name = 'an existing psmux session'; args = @{ command = 'Write-Output x'; mode = 'sync' }; env = @{ PSMUX_SESSION = 'existing' } }
        @{ name = 'a missing psmux installation'; args = @{ command = 'Write-Output x'; mode = 'sync' }; env = @{
                PATH = "$PSHOME;$env:WINDIR\System32"
                LOCALAPPDATA = (Join-Path $TestDrive 'missing-local-app-data')
            } }
    )

    foreach ($case in $skipCases) {
        It "does not rewrite $($case.name)" {
            $result = Invoke-Hook $case.args $case.env
            @($result.PSObject.Properties).Count | Should Be 0
        }
    }

    It 'removes abandoned hook command files after their retention period' {
        $tempRoot = Join-Path $env:TEMP 'long-run-hook'
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        $staleFile = Join-Path $tempRoot (
            'command-stale-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $staleFile -Value 'stale command'
        (Get-Item -LiteralPath $staleFile).LastWriteTimeUtc =
            [DateTime]::UtcNow.AddHours(-25)
        try {
            Invoke-Hook @{
                command = 'psmux list-sessions'
                mode = 'sync'
            } | Out-Null
            Test-Path -LiteralPath $staleFile | Should Be $false
        } finally {
            Remove-Item -LiteralPath $staleFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Publish-LongRunUrl' {
    It 'provides a named Markdown remote session link as post-tool context' {
        $url = 'https://example.devtunnels.ms/tmux/session/test-session/?accessToken=synthetic-capability'
        $result = Invoke-PublishUrlHook @"
Long-running command session: test-session
LONGRUN_REMOTE_URL=$url
LONGRUN_TMUX_URL=https://example.devtunnels.ms/tmux/
"@

        $result.additionalContext | Should Match (
            [regex]::Escape("[Remote session: test-session]($url)"))
        $result.additionalContext | Should Match 'rather than a bare URL'
        $result.additionalContext | Should Match 'next user-visible response'
        $result.additionalContext | Should Match 'include every supplied link'
        $result.additionalContext | Should Match 'Do not substitute the inventory URL'
    }

    It 'falls back to a generic Markdown label when the session name is absent' {
        $url = 'https://example.devtunnels.ms/tmux/session/test-session/?accessToken=synthetic-capability'
        $result = Invoke-PublishUrlHook "LONGRUN_REMOTE_URL=$url"

        $result.additionalContext | Should Match (
            [regex]::Escape("[Remote session]($url)"))
    }

    It 'does not add context when long-run did not publish a session URL' {
        $result = Invoke-PublishUrlHook 'ordinary PowerShell output'

        @($result.PSObject.Properties).Count | Should Be 0
    }
}

Describe 'Long-run diagnostics' {
    It 'records hook wrap and skip decisions without command text' {
        $logPath = Join-Path $TestDrive 'hook-events.jsonl'
        $wrapped = Invoke-Hook @{
            command = "Write-Output 'do-not-log-this'"
            description = 'Run a normal command'
            mode = 'sync'
        } @{ LONG_RUN_LOG_PATH = $logPath }
        $match = [regex]::Match($wrapped.modifiedArgs.command, "-CommandFile '([^']+)'")
        Remove-Item -LiteralPath $match.Groups[1].Value -Force

        Invoke-Hook @{
            command = 'psmux list-sessions'
            mode = 'sync'
        } @{ LONG_RUN_LOG_PATH = $logPath } | Out-Null

        $lines = @(Get-Content -LiteralPath $logPath)
        $events = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | Where-Object event -EQ 'wrapped').Count | Should Be 1
        @($events | Where-Object {
                $_.event -eq 'skipped' -and $_.reason -eq 'psmux-command'
            }).Count | Should Be 1
        ($lines -join "`n") | Should Not Match 'do-not-log-this'
    }

    It 'writes concurrent redacted JSONL events without changing behavior on failure' {
            $common = Join-Path $scriptRoot 'LongRun.Common.ps1'
            . $common
            $logPath = Join-Path $TestDrive 'events.jsonl'
            $savedLogPath = $env:LONG_RUN_LOG_PATH
            try {
                $env:LONG_RUN_LOG_PATH = $logPath
                (Get-LongRunGatewayLogPath (Join-Path $TestDrive 'gateway-a')) |
                    Should Match 'events\.gateway-[a-f0-9]{12}\.jsonl$'
                (Get-LongRunGatewayLogPath (Join-Path $TestDrive 'gateway-a')) |
                    Should Be (Get-LongRunGatewayLogPath (Join-Path $TestDrive 'gateway-a'))
                (Get-LongRunGatewayLogPath (Join-Path $TestDrive 'gateway-a')) |
                    Should Not Be (Get-LongRunGatewayLogPath (Join-Path $TestDrive 'gateway-b'))
                $processes = 1..8 | ForEach-Object {
                    $command = ". '$($common -replace "'", "''")'; " +
                        "Write-LongRunLog -Component test -Event concurrent " +
                        "-Session command-secret-$_ -Data @{ index = $_; accessToken = 'secret'; command = 'private' }"
                    $encoded = [Convert]::ToBase64String(
                        [Text.Encoding]::Unicode.GetBytes($command))
                    Start-Process pwsh -ArgumentList @(
                        '-NoProfile', '-EncodedCommand', $encoded
                    ) -PassThru -WindowStyle Hidden
                }
                $processes | Wait-Process

                $lines = @(Get-Content -LiteralPath $logPath)
                $lines.Count | Should Be 8
                $events = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
                @($events | Where-Object event -EQ 'concurrent').Count | Should Be 8
                @($events | Where-Object sessionHash).Count | Should Be 8
                ($lines -join "`n") | Should Not Match 'secret|private|accessToken|command-secret'

                $env:LONG_RUN_LOG_PATH = $TestDrive
                { Write-LongRunLog -Component test -Event ignored } | Should Not Throw
                @(Get-Content -LiteralPath $logPath).Count | Should Be 8
            } finally {
                $env:LONG_RUN_LOG_PATH = $savedLogPath
        }
    }

}

Describe 'Completed-session archive cleanup' {
        BeforeEach {
            . (Join-Path $scriptRoot 'LongRun.Common.ps1')
            . (Join-Path $scriptRoot 'LongRun.Completed.ps1')
            $archiveRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $archiveRoot | Out-Null
            $script:completedSessionMapFailure = $false
            function Invoke-PsmuxSetupCommand {
                [pscustomobject]@{
                    ExitCode = if ($script:completedSessionMapFailure) {
                        2
                    } else {
                        1
                    }
                    Output = ''
                }
            }
        }

        function New-TestCompletedArchive(
            [string]$Root,
            [string]$Name,
            [DateTimeOffset]$CompletedAt,
            [DateTimeOffset]$ExpiresAt,
            [int]$Bytes = 1
        ) {
            $directory = Join-Path $Root $Name
            New-Item -ItemType Directory -Path $directory | Out-Null
            [IO.File]::WriteAllBytes(
                (Join-Path $directory 'transcript.log'),
                [byte[]]::new($Bytes))
            [IO.File]::WriteAllText(
                (Join-Path $directory 'manifest.json'),
                ([ordered]@{
                        schemaVersion = 1
                        archiveId = $Name
                        session = "session-$Name"
                        completedAt = $CompletedAt.ToString('o')
                        expiresAt = $ExpiresAt.ToString('o')
                        exitCode = 0
                        captureComplete = $true
                        transcriptBytes = $Bytes
                        psmuxCreated = 0
                        psmuxId = $null
                    } | ConvertTo-Json),
                [Text.UTF8Encoding]::new($false))
            return $directory
        }

        It 'evicts expired and oldest archives to the count limit' {
            $now = [DateTimeOffset]::UtcNow
            $expired = New-TestCompletedArchive $archiveRoot 'expired' `
                $now.AddMinutes(-4) $now.AddMinutes(-1)
            $oldest = New-TestCompletedArchive $archiveRoot 'oldest' `
                $now.AddMinutes(-3) $now.AddHours(1)
            $middle = New-TestCompletedArchive $archiveRoot 'middle' `
                $now.AddMinutes(-2) $now.AddHours(1)
            $newest = New-TestCompletedArchive $archiveRoot 'newest' `
                $now.AddMinutes(-1) $now.AddHours(1)

            Invoke-LongRunCompletedCleanupUnlocked `
                -ArchiveRoot $archiveRoot `
                -PsmuxPath 'test-psmux' `
                -SessionLimit 2 `
                -StorageLimitBytes 10MB

            (Test-Path -LiteralPath $expired) | Should Be $false
            (Test-Path -LiteralPath $oldest) | Should Be $false
            (Test-Path -LiteralPath $middle) | Should Be $true
            (Test-Path -LiteralPath $newest) | Should Be $true
        }

        It 'evicts oldest archives to the storage budget' {
            $now = [DateTimeOffset]::UtcNow
            $oldest = New-TestCompletedArchive $archiveRoot 'oldest-large' `
                $now.AddMinutes(-2) $now.AddHours(1) 700KB
            $newest = New-TestCompletedArchive $archiveRoot 'newest-large' `
                $now.AddMinutes(-1) $now.AddHours(1) 700KB

            Invoke-LongRunCompletedCleanupUnlocked `
                -ArchiveRoot $archiveRoot `
                -PsmuxPath 'test-psmux' `
                -SessionLimit 10 `
                -StorageLimitBytes 1MB

            (Test-Path -LiteralPath $oldest) | Should Be $false
            (Test-Path -LiteralPath $newest) | Should Be $true
    }

    It 'preserves archives when psmux session enumeration fails' {
            $now = [DateTimeOffset]::UtcNow
            $directory = New-TestCompletedArchive $archiveRoot 'list-failure' `
                $now.AddMinutes(-1) $now.AddMinutes(-1)
            $script:completedSessionMapFailure = $true

            Invoke-LongRunCompletedCleanupUnlocked `
                -ArchiveRoot $archiveRoot `
                -PsmuxPath 'test-psmux' `
                -SessionLimit 0 `
                -StorageLimitBytes 0

            (Test-Path -LiteralPath $directory) | Should Be $true
    }

    It 'preserves an archive record when its exact session cannot be removed' {
            $now = [DateTimeOffset]::UtcNow
            $directory = New-TestCompletedArchive $archiveRoot 'kill-failure' `
                $now.AddMinutes(-1) $now.AddHours(1)
            $manifestPath = Join-Path $directory 'manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw |
                ConvertFrom-Json
            $manifest.psmuxCreated = 1700000000
            $manifest.psmuxId = '$42'
            [IO.File]::WriteAllText(
                $manifestPath,
                ($manifest | ConvertTo-Json),
                [Text.UTF8Encoding]::new($false))
            $record = @(Get-LongRunCompletedArchiveRecords $archiveRoot)[0]
            $fakePsmux = Join-Path $TestDrive 'failed-kill-psmux.cmd'
            [IO.File]::WriteAllText(
                $fakePsmux,
                @'
@echo off
if "%1"=="list-sessions" (
  echo session-kill-failure	1700000000	$42
  exit /b 0
)
if "%1"=="kill-session" exit /b 1
exit /b 0
'@,
                [Text.Encoding]::ASCII)
            $threw = $false
            try {
                Remove-LongRunCompletedArchiveRecord `
                    -Record $record `
                    -PsmuxPath $fakePsmux `
                    -Reason 'test'
            } catch {
                $threw = $true
            }
            $threw | Should Be $true
            (Test-Path -LiteralPath $directory) | Should Be $true
    }

    It 'reports a locked archive so expiry cleanup can retry it' {
            $now = [DateTimeOffset]::UtcNow
            $directory = New-TestCompletedArchive $archiveRoot 'locked-archive' `
                $now.AddMinutes(-1) $now.AddHours(1)
            $record = @(Get-LongRunCompletedArchiveRecords $archiveRoot)[0]
            $lock = [IO.File]::Open(
                (Join-Path $directory 'transcript.log'),
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None)
            try {
                $threw = $false
                try {
                    Remove-LongRunCompletedArchiveRecord `
                        -Record $record `
                        -PsmuxPath 'unused' `
                        -Reason 'test'
                } catch {
                    $threw = $true
                }
                $threw | Should Be $true
                (Test-Path -LiteralPath $directory) | Should Be $true
                (Test-Path -LiteralPath (
                        Join-Path $directory 'manifest.json')) | Should Be $true
            } finally {
                $lock.Dispose()
            }
    }
}
