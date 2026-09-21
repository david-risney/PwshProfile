$pluginRoot = Split-Path -Parent $PSScriptRoot
$scriptRoot = Join-Path $pluginRoot 'skills\long-run\scripts'
$startShellScript = Join-Path $scriptRoot 'Start-LongRunShell.ps1'

function New-CommandWrapper([string]$Directory, [string]$Name, [string]$Body) {
    $scriptPath = Join-Path $Directory "$Name.ps1"
    $commandPath = Join-Path $Directory "$Name.cmd"
    $Body | Set-Content -LiteralPath $scriptPath -Encoding utf8
    "@pwsh -NoProfile -File `"%~dp0$Name.ps1`" %*" |
        Set-Content -LiteralPath $commandPath -Encoding ascii
    return $commandPath
}

function New-ShellTestPsmux([string]$Directory) {
    $escapedDirectory = $Directory -replace "'", "''"
    $body = @'
$root = '__TEST_ROOT__'
$active = Join-Path $root 'active'
$sessionFile = Join-Path $root 'session'
[System.IO.File]::AppendAllText(
    (Join-Path $root 'psmux-calls.jsonl'),
    (($args | ConvertTo-Json -Compress) + [Environment]::NewLine))
switch ($args[0]) {
    'new-session' {
        [pscustomobject]@{
            ordinary = $env:LONG_RUN_SHELL_TEST_VALUE
            noColor = $env:NO_COLOR
            forceColor = $env:FORCE_COLOR
            copilot = $env:COPILOT_CLI
            dragon = $env:DRAGON_INSTANCE
            gitPrompt = $env:GIT_TERMINAL_PROMPT
            psmuxConfig = $env:PSMUX_CONFIG_FILE
            psmuxPicker = $env:PSMUX_PICKER_SCRIPT
        } | ConvertTo-Json | Set-Content -LiteralPath (
            Join-Path $root 'child-environment.json')
        $sessionName = $args[[Array]::IndexOf($args, '-s') + 1]
        Set-Content -LiteralPath $sessionFile -Value $sessionName -NoNewline
        New-Item -ItemType File -Path $active -Force | Out-Null
        exit 0
    }
    'list-sessions' {
        if (Test-Path -LiteralPath $active) {
            "$(Get-Content -LiteralPath $sessionFile -Raw)`t1700000000`t`$1"
            exit 0
        }
        exit 1
    }
    'has-session' {
        if (Test-Path -LiteralPath $active) { exit 0 }
        exit 1
    }
    'kill-session' {
        New-Item -ItemType File -Path (Join-Path $root 'killed') -Force | Out-Null
        Remove-Item -LiteralPath $active -Force -ErrorAction SilentlyContinue
        exit 0
    }
    default { exit 0 }
}
'@
    return New-CommandWrapper $Directory 'fake-psmux' (
        $body.Replace('__TEST_ROOT__', $escapedDirectory))
}

function Wait-Condition([scriptblock]$Condition, [int]$TimeoutSeconds = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

Describe 'Start-LongRunShell' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $fakePsmux = New-ShellTestPsmux $root
        $session = 'shell-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $stateDir = Join-Path $env:TEMP "long-run-shell\$session"
    }

    AfterEach {
        Remove-Item -LiteralPath (Join-Path $root 'active') `
            -Force -ErrorAction SilentlyContinue
        if ($stateDir) {
            Wait-Condition { -not (Test-Path -LiteralPath $stateDir) } 5 | Out-Null
        }
        if ($stateDir -and (Test-Path -LiteralPath $stateDir)) {
            Remove-Item -LiteralPath $stateDir -Recurse -Force
        }
    }

    It 'starts a detached named shell with cwd and environment metadata' {
        $names = @(
            'LONG_RUN_SHELL_TEST_VALUE',
            'NO_COLOR',
            'FORCE_COLOR',
            'COPILOT_CLI',
            'DRAGON_INSTANCE',
            'GIT_TERMINAL_PROMPT',
            'PSMUX_CONFIG_FILE',
            'PSMUX_PICKER_SCRIPT')
        $saved = @{}
        foreach ($name in $names) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        try {
            $env:LONG_RUN_SHELL_TEST_VALUE = 'shell-environment-value'
            $env:NO_COLOR = '1'
            $env:FORCE_COLOR = 'false'
            $env:COPILOT_CLI = '1'
            $env:DRAGON_INSTANCE = 'test'
            $env:GIT_TERMINAL_PROMPT = '0'
            $env:PSMUX_CONFIG_FILE = 'C:\profile\psmux.conf'
            $env:PSMUX_PICKER_SCRIPT = 'C:\profile\psmux-picker.ps1'
            $output = & $startShellScript `
                -Session $session -WorkingDirectory $TestDrive -RemoteMode Never `
                -PsmuxPath $fakePsmux -NoOpen 6>&1
        } finally {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable(
                    $name, $saved[$name], 'Process')
            }
        }
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match "Connect locally: .*attach-session -t '$session'"
        ($output -join "`n") | Should Match 'LONGRUN_SHELL_REMOTE=false'
        ($output -join "`n") | Should Match 'LONGRUN_SHELL_LOCAL_OPENED=false'

        $calls = Get-Content (Join-Path $root 'psmux-calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate }
        $newSession = @($calls | Where-Object { $_[0] -eq 'new-session' })[0]
        ($newSession -contains '-d') | Should Be $true
        ($newSession -contains $session) | Should Be $true

        $savedEnvironment = Get-Content (Join-Path $stateDir 'environment.json') -Raw |
            ConvertFrom-Json
        $savedEnvironment.LONG_RUN_SHELL_TEST_VALUE | Should Be 'shell-environment-value'
        $savedEnvironment.NO_COLOR | Should BeNullOrEmpty
        $savedEnvironment.FORCE_COLOR | Should BeNullOrEmpty
        $savedEnvironment.COPILOT_CLI | Should BeNullOrEmpty
        $savedEnvironment.DRAGON_INSTANCE | Should BeNullOrEmpty
        $savedEnvironment.GIT_TERMINAL_PROMPT | Should BeNullOrEmpty
        $savedEnvironment.PSMUX_CONFIG_FILE | Should Be 'C:\profile\psmux.conf'
        $savedEnvironment.PSMUX_PICKER_SCRIPT | Should Be 'C:\profile\psmux-picker.ps1'
        $childEnvironment = Get-Content (
            Join-Path $root 'child-environment.json') -Raw | ConvertFrom-Json
        $childEnvironment.ordinary | Should Be 'shell-environment-value'
        $childEnvironment.noColor | Should BeNullOrEmpty
        $childEnvironment.forceColor | Should BeNullOrEmpty
        $childEnvironment.copilot | Should BeNullOrEmpty
        $childEnvironment.dragon | Should BeNullOrEmpty
        $childEnvironment.gitPrompt | Should BeNullOrEmpty
        $childEnvironment.psmuxConfig | Should Be 'C:\profile\psmux.conf'
        $childEnvironment.psmuxPicker | Should Be 'C:\profile\psmux-picker.ps1'
        $metadata = Get-Content (Join-Path $stateDir 'session.json') -Raw |
            ConvertFrom-Json
        $metadata.shellPath | Should Be (Get-Command pwsh -CommandType Application).Source
        $bootstrap = Get-Content (Join-Path $stateDir 'bootstrap.ps1') -Raw
        $bootstrap | Should Match ([regex]::Escape((Resolve-Path $TestDrive).Path))
        $bootstrap | Should Match 'source-file \$env:PSMUX_CONFIG_FILE'
        $bootstrap | Should Match 'set-environment \$entry.Key \$entry.Value'

        Remove-Item (Join-Path $root 'active') -Force
        (Wait-Condition { -not (Test-Path -LiteralPath $stateDir) } 20) |
            Should Be $true
    }

    It 'publishes the shared inventory and session URL in remote mode' {
        $gatewayScript = Join-Path $root 'fake-gateway.ps1'
        @'
param(
    [int]$TunnelExpirationDays,
    [int]$TerminalStartupIdleSeconds,
    [switch]$AllowAnonymous,
    [string]$PsmuxPath
)
[pscustomobject]@{
    Url = 'https://example.usw2.devtunnels.ms/tmux/?accessToken=test-capability'
    BaseUrl = 'https://example.usw2.devtunnels.ms'
    TerminalCapability = 'test-capability'
    Reused = $true
}
'@ | Set-Content -LiteralPath $gatewayScript -Encoding utf8

        $output = & $startShellScript `
            -Session $session -WorkingDirectory $TestDrive -RemoteMode Always `
            -PsmuxPath $fakePsmux -ShellPath (Get-Command pwsh).Source `
            -GatewayScript $gatewayScript 6>&1
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match 'LONGRUN_SHELL_REMOTE=true'
        ($output -join "`n") | Should Match (
            "LONGRUN_SHELL_REMOTE_URL=https://example\.usw2\.devtunnels\.ms/tmux/session/$session/\?accessToken=test-capability")
        ($output -join "`n") | Should Match (
            'LONGRUN_TMUX_URL=https://example\.usw2\.devtunnels\.ms/tmux/\?accessToken=test-capability')

        $metadata = Get-Content (Join-Path $stateDir 'session.json') -Raw |
            ConvertFrom-Json
        $metadata.remoteUrl | Should Be "https://example.usw2.devtunnels.ms/tmux/session/$session/?accessToken=test-capability"
        $metadata.inventoryUrl | Should Be 'https://example.usw2.devtunnels.ms/tmux/?accessToken=test-capability'

        Remove-Item (Join-Path $root 'active') -Force
        (Wait-Condition { -not (Test-Path -LiteralPath $stateDir) } 20) |
            Should Be $true
    }

    It 'opens a local Windows Terminal tab by default' {
        $terminalLog = Join-Path $root 'terminal-args.json'
        $terminalBody = @'
[System.IO.File]::WriteAllText(
    '__TERMINAL_LOG__',
    ($args | ConvertTo-Json -Compress))
'@.Replace('__TERMINAL_LOG__', $terminalLog.Replace("'", "''"))
        $fakeTerminal = New-CommandWrapper $root 'fake-terminal' $terminalBody

        $output = & $startShellScript `
            -Session $session -WorkingDirectory $TestDrive -RemoteMode Never `
            -PsmuxPath $fakePsmux -WindowsTerminalPath $fakeTerminal 6>&1

        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match 'LONGRUN_SHELL_LOCAL_OPENED=true'
        (Wait-Condition { Test-Path -LiteralPath $terminalLog } 5) |
            Should Be $true
        $terminalArguments = Get-Content $terminalLog -Raw |
            ConvertFrom-Json -NoEnumerate
        ($terminalArguments -contains 'new-tab') | Should Be $true
        ($terminalArguments -contains $session) | Should Be $true
        ($terminalArguments -contains 'attach-session') | Should Be $true

        Remove-Item (Join-Path $root 'active') -Force
        (Wait-Condition { -not (Test-Path -LiteralPath $stateDir) } 20) |
            Should Be $true
    }

    It 'keeps an automatic remote shell when gateway startup fails' {
        $gatewayScript = Join-Path $root 'failing-gateway.ps1'
        Set-Content -LiteralPath $gatewayScript -Value "throw 'ttyd was not found'"
        $savedRemote = $env:DRAGON_REMOTE
        try {
            $env:DRAGON_REMOTE = '1'
            $output = & $startShellScript `
                -Session $session -WorkingDirectory $TestDrive -RemoteMode Auto `
                -PsmuxPath $fakePsmux -ShellPath (Get-Command pwsh).Source `
                -GatewayScript $gatewayScript -NoOpen 6>&1 3>&1

            $LASTEXITCODE | Should Be 0
            ($output -join "`n") | Should Match 'continuing locally'
            ($output -join "`n") | Should Match 'LONGRUN_SHELL_REMOTE=false'
            Test-Path -LiteralPath (Join-Path $root 'active') | Should Be $true
        } finally {
            $env:DRAGON_REMOTE = $savedRemote
            Remove-Item (Join-Path $root 'active') -Force `
                -ErrorAction SilentlyContinue
        }
        (Wait-Condition { -not (Test-Path -LiteralPath $stateDir) } 20) |
            Should Be $true
    }

    It 'generates a bootstrap compatible with Windows PowerShell' {
        $windowsPowerShell = (Get-Command powershell.exe).Source
        & $startShellScript `
            -Session $session -WorkingDirectory $TestDrive -RemoteMode Never `
            -PsmuxPath $fakePsmux -ShellPath $windowsPowerShell `
            -NoOpen 6>&1 | Out-Null

        $bootstrap = Join-Path $stateDir 'bootstrap.ps1'
        (Get-Content $bootstrap -Raw) | Should Not Match 'AsHashtable'
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $bootstrap
        $LASTEXITCODE | Should Be 0

        Remove-Item (Join-Path $root 'active') -Force
        (Wait-Condition { -not (Test-Path -LiteralPath $stateDir) } 20) |
            Should Be $true
    }

    It 'does not kill a session that wins a creation race' {
        New-Item -ItemType File -Path (Join-Path $root 'active') | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'session') `
            -Value $session -NoNewline

        & pwsh -NoProfile -File $startShellScript `
            -Session $session -WorkingDirectory $TestDrive `
            -RemoteMode Never -PsmuxPath $fakePsmux 2>$null

        $LASTEXITCODE | Should Not Be 0
        (Test-Path -LiteralPath (Join-Path $root 'active')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $root 'killed')) | Should Be $false
    }

    It 'does not delete a state directory owned by another invocation' {
        New-Item -ItemType Directory -Path $stateDir | Out-Null
        $marker = Join-Path $stateDir 'owned-by-other-run'
        Set-Content -LiteralPath $marker -Value 'keep'

        & pwsh -NoProfile -File $startShellScript `
            -Session $session -WorkingDirectory $TestDrive `
            -RemoteMode Never -PsmuxPath $fakePsmux 2>$null

        $LASTEXITCODE | Should Not Be 0
        (Test-Path -LiteralPath $marker) | Should Be $true
    }

    It 'rejects dot-segment session names without deleting shared state' {
        $stateRoot = Join-Path $env:TEMP 'long-run-shell'
        New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
        $marker = Join-Path $stateRoot 'shared-state-marker'
        Set-Content -LiteralPath $marker -Value 'keep'

        & pwsh -NoProfile -File $startShellScript `
            -Session '.' -WorkingDirectory $TestDrive `
            -RemoteMode Never -PsmuxPath $fakePsmux 2>$null

        $LASTEXITCODE | Should Not Be 0
        (Test-Path -LiteralPath $marker) | Should Be $true
        Remove-Item -LiteralPath $marker -Force
    }
}
