$pluginRoot = Split-Path -Parent $PSScriptRoot
$scriptRoot = Join-Path $pluginRoot 'skills\long-run\scripts'
$startScript = Join-Path $scriptRoot 'Start-LongRun.ps1'
$watchScript = Join-Path $scriptRoot 'Watch-LongRunSession.ps1'
$hookScript = Join-Path $pluginRoot 'hooks\Invoke-LongRunHook.ps1'

function New-FakePsmux([string]$Directory) {
    $scriptPath = Join-Path $Directory 'fake-psmux.ps1'
    @'
$root = $env:TEST_PSMUX_ROOT
$active = Join-Path $root 'active'
$sessionFile = Join-Path $root 'session'
$log = Join-Path $root 'calls.jsonl'
switch ($args[0]) {
    'new-session' {
        [System.IO.File]::AppendAllText(
            $log,
            (($args | ConvertTo-Json -Compress) + [Environment]::NewLine))
        $sessionName = $args[[Array]::IndexOf($args, '-s') + 1]
        Set-Content -LiteralPath $sessionFile -Value $sessionName -NoNewline
        New-Item -ItemType File -Path $active -Force | Out-Null
        $separator = [Array]::IndexOf($args, '--')
        if ($separator -lt 0) {
            $separator = [Array]::FindIndex(
                [string[]]$args,
                [Predicate[string]]{ param($value) $value -match '(?i)(?:^|[\\/])pwsh(?:\.exe)?$' }) - 1
        }
        $program = $args[$separator + 1]
        $programArgs = @($args[($separator + 2)..($args.Count - 1)])
        & $program @programArgs
        Remove-Item -LiteralPath $active -Force -ErrorAction SilentlyContinue
        exit 0
    }
    'has-session' {
        if (Test-Path -LiteralPath $active) { exit 0 }
        exit 1
    }
    'list-sessions' {
        if (Test-Path -LiteralPath $active) {
            "$(Get-Content -LiteralPath $sessionFile -Raw)`t1700000000`t`$1"
            exit 0
        }
        exit 1
    }
    'kill-session' {
        New-Item -ItemType File -Path (Join-Path $root 'killed') -Force | Out-Null
        Remove-Item -LiteralPath $active -Force -ErrorAction SilentlyContinue
        exit 0
    }
    default { exit 0 }
}
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8
    $path = Join-Path $Directory 'fake-psmux.cmd'
    '@pwsh -NoProfile -File "%~dp0fake-psmux.ps1" %*' |
        Set-Content -LiteralPath $path -Encoding ascii
    return $path
}

function Invoke-Hook([hashtable]$ToolArgs, [hashtable]$Environment = @{}) {
    $payload = @{
        sessionId = 'test-session'
        timestamp = 0
        cwd = (Resolve-Path -LiteralPath $TestDrive).Path
        toolName = 'powershell'
        toolArgs = $ToolArgs
    } | ConvertTo-Json -Compress -Depth 10

    $saved = @{}
    $pwsh = (Get-Command pwsh -CommandType Application).Source
    try {
        $saved.COPILOT_PLUGIN_ROOT = $env:COPILOT_PLUGIN_ROOT
        $env:COPILOT_PLUGIN_ROOT = $pluginRoot
        foreach ($entry in $Environment.GetEnumerator()) {
            $saved[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
            [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
        }
        return ($payload | & $pwsh -NoProfile -File $hookScript | ConvertFrom-Json)
    } finally {
        foreach ($entry in $saved.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }
}

function Wait-Condition([scriptblock]$Condition, [int]$TimeoutSeconds = 10) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

Describe 'Start-LongRun' {
    BeforeEach {
        $env:TEST_PSMUX_ROOT = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $env:TEST_PSMUX_ROOT | Out-Null
        $fakePsmux = New-FakePsmux $env:TEST_PSMUX_ROOT
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
                '-NoViewer'
            )
        try {
            Start-Sleep -Milliseconds 300
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
        $result.modifiedArgs.command | Should Match 'finally \{ Remove-Item'
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $result.modifiedArgs.command, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0

        $match = [regex]::Match($result.modifiedArgs.command, "-CommandFile '([^']+)'")
        $match.Success | Should Be $true
        [System.IO.File]::ReadAllText($match.Groups[1].Value) | Should Be "Write-Output 'quoted value'"
        Remove-Item -LiteralPath $match.Groups[1].Value -Force
    }

    $skipCases = @(
        @{ name = 'a psmux command'; args = @{ command = 'psmux list-sessions'; mode = 'sync' }; env = @{} },
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
}
