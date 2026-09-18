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
        $env:LONG_RUN_SHELL_TEST_VALUE = 'shell-environment-value'
        $output = & $startShellScript `
            -Session $session -WorkingDirectory $TestDrive -RemoteMode Never `
            -PsmuxPath $fakePsmux 6>&1
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match "Connect locally: .*attach-session -t '$session'"
        ($output -join "`n") | Should Match 'LONGRUN_SHELL_REMOTE=false'

        $calls = Get-Content (Join-Path $root 'psmux-calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate }
        $newSession = @($calls | Where-Object { $_[0] -eq 'new-session' })[0]
        ($newSession -contains '-d') | Should Be $true
        ($newSession -contains $session) | Should Be $true

        $savedEnvironment = Get-Content (Join-Path $stateDir 'environment.json') -Raw |
            ConvertFrom-Json
        $savedEnvironment.LONG_RUN_SHELL_TEST_VALUE | Should Be 'shell-environment-value'
        $savedEnvironment.NO_COLOR | Should BeNullOrEmpty
        $metadata = Get-Content (Join-Path $stateDir 'session.json') -Raw |
            ConvertFrom-Json
        $metadata.shellPath | Should Be (Get-Command pwsh -CommandType Application).Source
        $bootstrap = Get-Content (Join-Path $stateDir 'bootstrap.ps1') -Raw
        $bootstrap | Should Match ([regex]::Escape((Resolve-Path $TestDrive).Path))

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

    It 'keeps an automatic remote shell when gateway startup fails' {
        $gatewayScript = Join-Path $root 'failing-gateway.ps1'
        Set-Content -LiteralPath $gatewayScript -Value "throw 'ttyd was not found'"
        $savedRemote = $env:DRAGON_REMOTE
        try {
            $env:DRAGON_REMOTE = '1'
            $output = & $startShellScript `
                -Session $session -WorkingDirectory $TestDrive -RemoteMode Auto `
                -PsmuxPath $fakePsmux -ShellPath (Get-Command pwsh).Source `
                -GatewayScript $gatewayScript 6>&1 3>&1

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
            -PsmuxPath $fakePsmux -ShellPath $windowsPowerShell 6>&1 | Out-Null

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
