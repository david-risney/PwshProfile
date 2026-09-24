$pluginRoot = Split-Path -Parent $PSScriptRoot
$scriptRoot = Join-Path $pluginRoot 'skills\long-run\scripts'
$startGateway = Join-Path $scriptRoot 'Start-LongRunMuxGateway.ps1'
$stopGateway = Join-Path $scriptRoot 'Stop-LongRunMuxGateway.ps1'

function New-GatewayCommandWrapper(
    [string]$Directory,
    [string]$Name,
    [string]$Body
) {
    $scriptPath = Join-Path $Directory "$Name.ps1"
    $commandPath = Join-Path $Directory "$Name.cmd"
    $Body | Set-Content -LiteralPath $scriptPath -Encoding utf8
    "@pwsh -NoProfile -File `"%~dp0$Name.ps1`" %*" |
        Set-Content -LiteralPath $commandPath -Encoding ascii
    return $commandPath
}

Describe 'Start-LongRunMuxGateway' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $stateDirectory = Join-Path $root 'gateway-state'
        $terminalFont = Join-Path $root 'terminal-font.ttf'
        [IO.File]::WriteAllBytes($terminalFont, [byte[]](1, 2, 3, 4))
        $escapedRoot = $root -replace "'", "''"

        $psmuxState = Join-Path $root 'fake-psmux-state.json'
        $escapedPsmuxState = $psmuxState.Replace('"', '""')
        $psmuxProject = Join-Path $root 'fake-psmux'
        & dotnet new console --name fake-psmux --framework net8.0 --no-restore `
            --output $psmuxProject | Out-Null
        @"
using System.Diagnostics;
using System.Text.Json;

public sealed record Session(string Id, string Name, long Created, int Pid);

public static class Program {
    private static readonly string StateFile = @`"$escapedPsmuxState`";

    private static List<Session> Load() {
        if (!File.Exists(StateFile)) return new();
        return JsonSerializer.Deserialize<List<Session>>(File.ReadAllText(StateFile)) ?? new();
    }

    private static void Save(List<Session> sessions) =>
        File.WriteAllText(StateFile, JsonSerializer.Serialize(sessions));

    private static bool Running(int pid) {
        try { return !Process.GetProcessById(pid).HasExited; }
        catch { return false; }
    }

    public static int Main(string[] args) {
        var sessions = Load().Where(session => Running(session.Pid)).ToList();
        Save(sessions);
        var targetIndex = Array.IndexOf(args, "-t");
        var target = targetIndex >= 0 ? args[targetIndex + 1] : null;
        switch (args.FirstOrDefault()) {
            case "list-sessions":
                var formatIndex = Array.IndexOf(args, "-F");
                var format = formatIndex >= 0
                    ? args[formatIndex + 1]
                    : "#{session_name}";
                foreach (var item in sessions) {
                    Console.WriteLine(format
                        .Replace("#{session_name}", item.Name)
                        .Replace("#{session_created}", item.Created.ToString())
                        .Replace("#{session_id}", item.Id)
                        .Replace("#{session_attached}", "0"));
                }
                return sessions.Count > 0 ? 0 : 1;
            case "has-session":
                return sessions.Any(session => session.Name == target) ? 0 : 1;
            case "list-panes":
                foreach (var item in sessions) {
                    Console.WriteLine(
                        item.Name + "|" + Environment.CurrentDirectory +
                        "|fake-command");
                }
                return sessions.Count > 0 ? 0 : 1;
            case "new-session":
                var separator = Array.IndexOf(args, "--");
                var nameIndex = Array.IndexOf(args, "-s");
                if (separator < 0 || nameIndex < 0) return 2;
                var name = args[nameIndex + 1];
                if (sessions.Any(session => session.Name == name)) return 1;
                var start = new ProcessStartInfo {
                    FileName = args[separator + 1],
                    UseShellExecute = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                foreach (var argument in args.Skip(separator + 2)) {
                    start.ArgumentList.Add(argument);
                }
                var process = Process.Start(start);
                if (process is null) return 3;
                sessions.Add(new Session(
                    "$" + Guid.NewGuid().ToString("N"),
                    name,
                    DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                    process.Id));
                Save(sessions);
                return 0;
            case "kill-session":
                var session = sessions.FirstOrDefault(
                    item => item.Name == target || item.Id == target);
                if (session is null) return 1;
                try {
                    Process.GetProcessById(session.Pid).Kill(true);
                } catch { }
                sessions.Remove(session);
                Save(sessions);
                return 0;
            default:
                return 0;
        }
    }
}
"@ | Set-Content (Join-Path $psmuxProject 'Program.cs') -Encoding utf8
        $buildOutput = & dotnet build $psmuxProject --configuration Release --nologo
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to build fake psmux.`n$($buildOutput -join "`n")"
        }
        $fakePsmux = Join-Path $psmuxProject 'bin\Release\net8.0\fake-psmux.exe'
        $devTunnelBody = @'
$root = '__TEST_ROOT__'
$statePath = Join-Path $root 'devtunnels.json'
$commandArguments = $args
[System.IO.File]::AppendAllText(
    (Join-Path $root 'devtunnel-calls.jsonl'),
    (($args | ConvertTo-Json -Compress) + [Environment]::NewLine))

function Get-ArgumentValue([string]$Name) {
    $index = [Array]::IndexOf($commandArguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $commandArguments.Count) { return $null }
    return $commandArguments[$index + 1]
}

function Get-ArgumentValues([string]$Name) {
    $values = @()
    for ($item = 0; $item -lt $commandArguments.Count - 1; $item++) {
        if ($commandArguments[$item] -eq $Name) {
            $values += $commandArguments[$item + 1]
        }
    }
    return $values
}

function Read-State {
    if (Test-Path -LiteralPath $statePath) {
        return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    }
    return [pscustomobject]@{ next = 1; tunnels = @() }
}

function Write-State([object]$State) {
    $State | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $statePath -Encoding utf8
}

function Write-Json([object]$Value) {
    'Warning: informational output before JSON.'
    $Value | ConvertTo-Json -Depth 10
    'Notice: informational output after JSON.'
}

$state = Read-State
switch ($args[0]) {
    'list' {
        if ($env:TEST_DEVTUNNEL_LIST_EXIT) {
            exit [int]$env:TEST_DEVTUNNEL_LIST_EXIT
        }
        $requiredLabels = @(Get-ArgumentValues '--all-labels')
        $tunnels = @($state.tunnels | Where-Object {
                $candidateLabels = @($_.labels)
                @($requiredLabels | Where-Object {
                        $_ -notin $candidateLabels
                    }).Count -eq 0
            })
        Write-Json ([pscustomobject]@{ tunnels = $tunnels })
        exit 0
    }
    'show' {
        if ($env:TEST_DEVTUNNEL_SHOW_EXIT) {
            exit [int]$env:TEST_DEVTUNNEL_SHOW_EXIT
        }
        $tunnel = @($state.tunnels | Where-Object tunnelId -EQ $args[1])[0]
        if (-not $tunnel) { exit 1 }
        Write-Json ([pscustomobject]@{ tunnel = $tunnel })
        exit 0
    }
    'update' {
        if ($env:TEST_DEVTUNNEL_UPDATE_EXIT) {
            exit [int]$env:TEST_DEVTUNNEL_UPDATE_EXIT
        }
        $tunnel = @($state.tunnels | Where-Object tunnelId -EQ $args[1])[0]
        if (-not $tunnel) { exit 1 }
        $labels = @(Get-ArgumentValues '--add-labels')
        $tunnel.labels = @($tunnel.labels + $labels | Sort-Object -Unique)
        $tunnel.tunnelExpiration = [DateTimeOffset]::UtcNow.AddDays(30).ToString('o')
        Write-State $state
        Write-Json ([pscustomobject]@{ tunnel = $tunnel })
        exit 0
    }
    'create' {
        $id = "fake-mux-$($state.next).usw2"
        $state.next = [int]$state.next + 1
        $labels = @(Get-ArgumentValues '-l')
        $tunnel = [pscustomobject]@{
            tunnelId = $id
            labels = $labels
            tunnelExpiration = [DateTimeOffset]::UtcNow.AddDays(30).ToString('o')
            ports = @()
        }
        $state.tunnels = @($state.tunnels) + $tunnel
        Write-State $state
        Write-Json ([pscustomobject]@{ tunnel = $tunnel })
        exit 0
    }
    'port' {
        $operation = $args[1]
        $id = $args[2]
        $tunnel = @($state.tunnels | Where-Object tunnelId -EQ $id)[0]
        if (-not $tunnel) { exit 1 }
        $portNumber = [int](Get-ArgumentValue '-p')
        if ($operation -eq 'update' -and $env:TEST_DEVTUNNEL_PORT_UPDATE_EXIT) {
            exit [int]$env:TEST_DEVTUNNEL_PORT_UPDATE_EXIT
        }
        $port = @($tunnel.ports | Where-Object {
                [int]$_.portNumber -eq $portNumber
            })[0]
        if (-not $port) {
            $port = [pscustomobject]@{
                portNumber = $portNumber
                protocol = 'http'
                portUri = "https://$id-$portNumber.devtunnels.ms"
                status = 'ready'
            }
            $tunnel.ports = @($tunnel.ports) + $port
        }
        Write-State $state
        Write-Json ([pscustomobject]@{ port = $port })
        exit 0
    }
    'host' {
        if ($env:TEST_DEVTUNNEL_HOST_EXIT) {
            exit [int]$env:TEST_DEVTUNNEL_HOST_EXIT
        }
        $tunnel = @($state.tunnels | Where-Object tunnelId -EQ $args[1])[0]
        if (-not $tunnel -or @($tunnel.ports).Count -eq 0) { exit 1 }
        $portNumber = [int]@($tunnel.ports)[0].portNumber
        "Connect via browser: https://$($tunnel.tunnelId)-$portNumber.devtunnels.ms"
        [Console]::Out.Flush()
        while ($true) { Start-Sleep -Seconds 60 }
    }
    'delete' {
        if ($env:TEST_DEVTUNNEL_DELETE_EXIT) {
            exit [int]$env:TEST_DEVTUNNEL_DELETE_EXIT
        }
        $state.tunnels = @($state.tunnels | Where-Object tunnelId -NE $args[1])
        Write-State $state
        exit 0
    }
}
'@.Replace('__TEST_ROOT__', $escapedRoot)
        $fakeDevTunnel = New-GatewayCommandWrapper $root 'fake-devtunnel' $devTunnelBody
    }

    AfterEach {
        if (Test-Path -LiteralPath (Join-Path $stateDirectory 'gateway.json')) {
            & $stopGateway -StateDirectory $stateDirectory
        }
        if ($fakePsmux -and (Test-Path -LiteralPath $fakePsmux)) {
            @(& $fakePsmux list-sessions -F '#{session_name}' 2>$null) |
                Where-Object { $_ } |
                ForEach-Object { & $fakePsmux kill-session -t $_ 2>$null }
        }
        if (Test-Path -LiteralPath $stateDirectory) {
            Remove-Item -LiteralPath $stateDirectory -Recurse -Force
        }
    }

    It 'reuses one reverse proxy and one dev tunnel' {
        $arguments = @{
            StateDirectory = $stateDirectory
            PsmuxPath = $fakePsmux
            TtydPath = $fakePsmux
            DevTunnelPath = $fakeDevTunnel
            NodePath = (Get-Command node).Source
            NpmPath = (Get-Command npm.cmd).Source
            TerminalFontPath = $terminalFont
        }

        $startOutput = @(& $startGateway @arguments -Verbose 4>&1)
        $verboseMessages = @($startOutput |
            Where-Object { $_ -is [Management.Automation.VerboseRecord] })
        $first = $startOutput |
            Where-Object { $_ -isnot [Management.Automation.VerboseRecord] }
        $first.Reused | Should Be $false
        $first.Url | Should Match (
            '^https://fake-mux-1\.usw2-\d+\.devtunnels\.ms/tmux/\?accessToken=.+$')
        $first.GatewaySession | Should Match '^long-run-util-gateway-\d+$'
        $first.TerminalCapability | Should Not BeNullOrEmpty
        Test-Path -LiteralPath (
            Join-Path $stateDirectory '.long-run-mux-gateway') | Should Be $true
        ($verboseMessages -join "`n") | Should Match 'Started gateway session'
        ($verboseMessages -join "`n") | Should Match 'Gateway health check passed'
        ($verboseMessages -join "`n") | Should Match 'attach-session'

        $webSession =
            New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $inventory = Invoke-WebRequest (
            "http://127.0.0.1:$($first.Port)/tmux/?accessToken=" +
            [uri]::EscapeDataString($first.TerminalCapability)) `
            -UseBasicParsing -SkipHttpErrorCheck -WebSession $webSession
        if ($inventory.StatusCode -ne 200) {
            throw $inventory.Content
        }
        $inventory.StatusCode | Should Be 200
        $inventory.Content | Should Match 'No user psmux sessions are running'
        $inventory.Content | Should Match 'Long-run utilities'
        $sessionResponse = Invoke-RestMethod `
            "http://127.0.0.1:$($first.Port)/tmux/api/sessions" `
            -WebSession $webSession
        (@($sessionResponse.sessions).name -contains $first.GatewaySession) |
            Should Be $true
        $gatewayInfo = @($sessionResponse.sessions |
            Where-Object name -EQ $first.GatewaySession)[0]
        $gatewayInfo.cwd | Should Not BeNullOrEmpty
        $gatewayInfo.command | Should Be 'fake-command'

        $second = & $startGateway @arguments
        $second.Reused | Should Be $true
        $second.TunnelId | Should Be $first.TunnelId
        $second.GatewayPid | Should Be $first.GatewayPid
        $second.GatewaySession | Should Be $first.GatewaySession
        $second.TerminalCapability | Should Be $first.TerminalCapability

        $calls = Get-Content (Join-Path $root 'devtunnel-calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate }
        @($calls | Where-Object { $_[0] -eq 'create' }).Count | Should Be 1
        (@($calls | Where-Object { $_[0] -eq 'create' })[0] -contains
            '--allow-anonymous') | Should Be $false
        @($calls | Where-Object { $_[0] -eq 'host' }).Count | Should Be 1
        $portCall = @($calls | Where-Object {
            $_[0] -eq 'port' -and $_[1] -eq 'create'
        })[0]
        ($portCall -contains '--host-header') | Should Be $true
        ($portCall -contains '--origin-header') | Should Be $true
        @($portCall | Where-Object { $_ -eq 'unchanged' }).Count | Should Be 2

        $arguments.TerminalStartupIdleSeconds = 121
        $arguments.AllowAnonymous = $true
        $third = & $startGateway @arguments
        $third.Reused | Should Be $false
        $third.TunnelReused | Should Be $false
        $third.GatewayPid | Should Not Be $first.GatewayPid
        $third.GatewaySession | Should Match '^long-run-util-gateway-\d+$'
        $calls = Get-Content (Join-Path $root 'devtunnel-calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate }
        @($calls | Where-Object { $_[0] -eq 'create' }).Count | Should Be 2
        (@($calls | Where-Object { $_[0] -eq 'create' })[1] -contains
            '--allow-anonymous') | Should Be $true

        & $stopGateway -StateDirectory $stateDirectory
        Test-Path -LiteralPath $stateDirectory | Should Be $false
        & $fakePsmux has-session -t $third.GatewaySession
        $LASTEXITCODE | Should Be 1
        $calls = Get-Content (Join-Path $root 'devtunnel-calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate }
        @($calls | Where-Object { $_[0] -eq 'delete' }).Count | Should Be 2
    }

    It 'starts locally with one command and no dev tunnel' {
        & $fakePsmux new-session -d -s long-run-util-gateway-1 -- `
            (Get-Command pwsh).Source -NoProfile -Command `
            'Start-Sleep -Seconds 60'
        $LASTEXITCODE | Should Be 0

        $result = & $startGateway `
            -LocalOnly `
            -Port 18787 `
            -StateDirectory $stateDirectory `
            -PsmuxPath $fakePsmux `
            -TtydPath $fakePsmux `
            -NodePath (Get-Command node).Source `
            -NpmPath (Get-Command npm.cmd).Source `
            -TerminalFontPath $terminalFont

        $result.Url | Should Match (
            '^http://127\.0\.0\.1:18787/tmux/\?accessToken=.+$')
        $result.TunnelId | Should BeNullOrEmpty
        $result.TunnelPid | Should BeNullOrEmpty
        $result.GatewaySession | Should Be 'long-run-util-gateway-2'
        Test-Path (Join-Path $root 'devtunnel-calls.jsonl') | Should Be $false

        $webSession =
            New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $inventory = Invoke-WebRequest $result.Url -UseBasicParsing `
            -WebSession $webSession
        $inventory.StatusCode | Should Be 200
        $inventory.Content | Should Match '/tmux/assets/logo.svg'
        $fontResponse = Invoke-WebRequest `
            "http://127.0.0.1:18787/tmux/assets/terminal-font.ttf" `
            -UseBasicParsing -WebSession $webSession
        $fontResponse.StatusCode | Should Be 200
        $fontResponse.RawContentLength | Should Be 4

        $again = & $startGateway `
            -LocalOnly `
            -Port 18787 `
            -StateDirectory $stateDirectory `
            -PsmuxPath $fakePsmux `
            -TtydPath $fakePsmux `
            -NodePath (Get-Command node).Source `
            -NpmPath (Get-Command npm.cmd).Source `
            -TerminalFontPath $terminalFont
        $again.Reused | Should Be $true
        $again.GatewayPid | Should Be $result.GatewayPid

        $metadataFile = Join-Path $stateDirectory 'gateway.json'
        $metadata = Get-Content $metadataFile -Raw | ConvertFrom-Json
        $metadata.gatewaySessionCreated = [long]$metadata.gatewaySessionCreated + 1
        $metadata | ConvertTo-Json -Compress | Set-Content $metadataFile -Encoding utf8
        & $stopGateway -StateDirectory $stateDirectory
        (Get-Process -Id $result.GatewayPid -ErrorAction SilentlyContinue) |
            Should BeNullOrEmpty
        Test-Path -LiteralPath $stateDirectory | Should Be $false
    }

    It 'retains gateway state when dev tunnel deletion fails' {
        New-Item -ItemType Directory -Path $stateDirectory | Out-Null
        $failingDevTunnel = New-GatewayCommandWrapper `
            $root 'failing-devtunnel' 'exit 9'
        $metadataPath = Join-Path $stateDirectory 'gateway.json'
        [System.IO.File]::WriteAllText(
            $metadataPath,
            (@{
                    tunnelId = 'failed-delete'
                    devTunnelPath = $failingDevTunnel
                    tunnelPid = 0
                    tunnelStartTimeUtcTicks = 0
                    tunnelRunnerPath = ''
                    gatewayPid = 0
                    gatewayStartTimeUtcTicks = 0
                    gatewayRunnerPath = ''
                } | ConvertTo-Json -Compress),
            [System.Text.UTF8Encoding]::new($false))
        try {
            $failure = $null
            try {
                & $stopGateway -StateDirectory $stateDirectory
            } catch {
                $failure = $_
            }
            $failure | Should Not BeNullOrEmpty
            $failure.Exception.Message | Should Match 'exit 9'
            Test-Path -LiteralPath $metadataPath | Should Be $true
        } finally {
            if (Test-Path -LiteralPath $metadataPath) {
                Remove-Item -LiteralPath $stateDirectory -Recurse -Force
            }
        }
    }

    It 'reuses the durable tunnel across a gateway replacement' {
        $arguments = @{
            StateDirectory = $stateDirectory
            PsmuxPath = $fakePsmux
            TtydPath = $fakePsmux
            DevTunnelPath = $fakeDevTunnel
            NodePath = (Get-Command node).Source
            NpmPath = (Get-Command npm.cmd).Source
            TerminalFontPath = $terminalFont
        }
        $first = & $startGateway @arguments
        $firstConfig = Get-Content -LiteralPath (
            Join-Path $stateDirectory 'config.json') -Raw |
            ConvertFrom-Json
        $firstConfig.csrfToken | Should Not BeNullOrEmpty

        $arguments.TerminalStartupIdleSeconds = 121
        $second = & $startGateway @arguments
        $secondConfig = Get-Content -LiteralPath (
            Join-Path $stateDirectory 'config.json') -Raw |
            ConvertFrom-Json

        $second.Reused | Should Be $false
        $second.TunnelReused | Should Be $true
        $second.TunnelId | Should Be $first.TunnelId
        $second.Port | Should Be $first.Port
        $second.BaseUrl | Should Be $first.BaseUrl
        $second.TerminalCapability | Should Be $first.TerminalCapability
        $secondConfig.csrfToken | Should Be $firstConfig.csrfToken
        $second.GatewayPid | Should Not Be $first.GatewayPid
        $calls = Get-Content (Join-Path $root 'devtunnel-calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate }
        @($calls | Where-Object { $_[0] -eq 'create' }).Count | Should Be 1
        @($calls | Where-Object {
                $_[0] -eq 'port' -and $_[1] -eq 'update'
            }).Count | Should Be 1
        @($calls | Where-Object { $_[0] -eq 'update' }).Count | Should Be 1
    }

    It 'deletes the durable tunnel when switching to local-only mode' {
        $arguments = @{
            StateDirectory = $stateDirectory
            PsmuxPath = $fakePsmux
            TtydPath = $fakePsmux
            DevTunnelPath = $fakeDevTunnel
            NodePath = (Get-Command node).Source
            NpmPath = (Get-Command npm.cmd).Source
            TerminalFontPath = $terminalFont
        }
        $remote = & $startGateway @arguments
        $metadataPath = Join-Path $stateDirectory 'gateway.json'
        $remoteMetadata = Get-Content -LiteralPath $metadataPath -Raw |
            ConvertFrom-Json
        $remoteMetadata.devTunnelPath = Join-Path $root 'missing-devtunnel.exe'
        [IO.File]::WriteAllText(
            $metadataPath,
            ($remoteMetadata | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false))

        $local = & $startGateway @arguments -LocalOnly -Port $remote.Port

        $local.Reused | Should Be $false
        $local.TunnelId | Should BeNullOrEmpty
        $local.BaseUrl | Should Be "http://127.0.0.1:$($remote.Port)"
        $metadata = Get-Content -LiteralPath $metadataPath -Raw |
            ConvertFrom-Json
        $metadata.localOnly | Should Be $true
        $metadata.tunnelId | Should BeNullOrEmpty
        $calls = Get-Content (Join-Path $root 'devtunnel-calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate }
        @($calls | Where-Object { $_[0] -eq 'delete' }).Count | Should Be 1
    }

    It 'discovers a durable tunnel by its stable labels' {
        $arguments = @{
            StateDirectory = $stateDirectory
            PsmuxPath = $fakePsmux
            TtydPath = $fakePsmux
            DevTunnelPath = $fakeDevTunnel
            NodePath = (Get-Command node).Source
            NpmPath = (Get-Command npm.cmd).Source
            TerminalFontPath = $terminalFont
        }
        $first = & $startGateway @arguments
        $metadataPath = Join-Path $stateDirectory 'gateway.json'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.PSObject.Properties.Remove('tunnelId')
        $metadata.PSObject.Properties.Remove('url')
        $metadata | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $metadataPath -Encoding utf8

        $second = & $startGateway @arguments

        $second.Reused | Should Be $false
        $second.TunnelReused | Should Be $true
        $second.TunnelId | Should Be $first.TunnelId
        $second.Port | Should Be $first.Port
        $second.BaseUrl | Should Be $first.BaseUrl
        $calls = Get-Content (Join-Path $root 'devtunnel-calls.jsonl') |
            ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate }
        @($calls | Where-Object { $_[0] -eq 'create' }).Count | Should Be 1
        @($calls | Where-Object { $_[0] -eq 'list' }).Count | Should Be 2
    }

    It 'creates a replacement when tunnel reuse and deletion both fail' {
        $arguments = @{
            StateDirectory = $stateDirectory
            PsmuxPath = $fakePsmux
            TtydPath = $fakePsmux
            DevTunnelPath = $fakeDevTunnel
            NodePath = (Get-Command node).Source
            NpmPath = (Get-Command npm.cmd).Source
            TerminalFontPath = $terminalFont
        }
        $first = & $startGateway @arguments
        $savedUpdateExit = $env:TEST_DEVTUNNEL_UPDATE_EXIT
        $savedDeleteExit = $env:TEST_DEVTUNNEL_DELETE_EXIT
        $savedLogPath = $env:LONG_RUN_LOG_PATH
        $logPath = Join-Path $root 'gateway-events.jsonl'
        try {
            $env:TEST_DEVTUNNEL_UPDATE_EXIT = '8'
            $env:TEST_DEVTUNNEL_DELETE_EXIT = '9'
            $env:LONG_RUN_LOG_PATH = $logPath
            $arguments.TerminalStartupIdleSeconds = 121

            $second = & $startGateway @arguments

            $second.Reused | Should Be $false
            $second.TunnelReused | Should Be $false
            $second.TunnelId | Should Not Be $first.TunnelId
            $calls = Get-Content (Join-Path $root 'devtunnel-calls.jsonl') |
                ForEach-Object { $_ | ConvertFrom-Json -NoEnumerate }
            @($calls | Where-Object { $_[0] -eq 'create' }).Count | Should Be 2
            @($calls | Where-Object { $_[0] -eq 'delete' }).Count | Should Be 1
            $logText = Get-Content -LiteralPath $logPath -Raw
            $events = $logText -split "`r?`n" | Where-Object { $_ } |
                ForEach-Object { ($_ | ConvertFrom-Json).event }
            ($events -contains 'tunnel-reuse-failed') | Should Be $true
            ($events -contains 'tunnel-delete-failed') | Should Be $true
            ($events -contains 'tunnel-create-succeeded') | Should Be $true
            $logText | Should Not Match ([regex]::Escape($first.TunnelId))
            $logText | Should Not Match ([regex]::Escape($second.TunnelId))
        } finally {
            $env:TEST_DEVTUNNEL_UPDATE_EXIT = $savedUpdateExit
            $env:TEST_DEVTUNNEL_DELETE_EXIT = $savedDeleteExit
            $env:LONG_RUN_LOG_PATH = $savedLogPath
        }
    }

    It 'refuses to delete a non-empty unowned state directory' {
            New-Item -ItemType Directory -Path $stateDirectory | Out-Null
            $marker = Join-Path $stateDirectory 'user-file.txt'
            Set-Content -LiteralPath $marker -Value 'keep'

            $failure = $null
            try {
                & $startGateway -LocalOnly -StateDirectory $stateDirectory `
                    -PsmuxPath $fakePsmux -TtydPath $fakePsmux `
                    -NodePath (Get-Command node).Source `
                    -NpmPath (Get-Command npm.cmd).Source `
                    -TerminalFontPath $terminalFont
            } catch {
                $failure = $_
            }

            $failure | Should Not BeNullOrEmpty
            $failure.Exception.Message | Should Match 'unowned gateway state directory'
            (Get-Content -LiteralPath $marker -Raw).Trim() | Should Be 'keep'
    }

    It 'does not reuse a gateway when its immutable session id changed' {
        $arguments = @{
            StateDirectory = $stateDirectory
            PsmuxPath = $fakePsmux
            TtydPath = $fakePsmux
            NodePath = (Get-Command node).Source
            NpmPath = (Get-Command npm.cmd).Source
            TerminalFontPath = $terminalFont
            LocalOnly = $true
        }
        $first = & $startGateway @arguments
        $metadataFile = Join-Path $stateDirectory 'gateway.json'
        $metadata = Get-Content -LiteralPath $metadataFile -Raw | ConvertFrom-Json
        $firstSessionId = $metadata.gatewaySessionId
        $metadata.gatewaySessionId = '$replacement'
        $metadata | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $metadataFile -Encoding utf8

        $second = & $startGateway @arguments

        $second.Reused | Should Be $false
        $replacementMetadata =
            Get-Content -LiteralPath $metadataFile -Raw | ConvertFrom-Json
        $replacementMetadata.gatewaySessionId | Should Not Be $firstSessionId
    }

    It 'does not reuse incomplete gateway metadata without a URL' {
        $arguments = @{
            StateDirectory = $stateDirectory
            PsmuxPath = $fakePsmux
            TtydPath = $fakePsmux
            NodePath = (Get-Command node).Source
            NpmPath = (Get-Command npm.cmd).Source
            TerminalFontPath = $terminalFont
            LocalOnly = $true
        }
        $first = & $startGateway @arguments
        $metadataFile = Join-Path $stateDirectory 'gateway.json'
        $metadata = Get-Content -LiteralPath $metadataFile -Raw | ConvertFrom-Json
        $metadata.PSObject.Properties.Remove('url')
        $metadata | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $metadataFile -Encoding utf8

        $second = & $startGateway @arguments

        $second.Reused | Should Be $false
        $second.GatewayPid | Should Not Be $first.GatewayPid
    }

    It 'does not terminate a process when stored identity data is stale' {
        . (Join-Path $scriptRoot 'LongRun.Common.ps1')
        (Get-LongRunGatewayMutexName $stateDirectory) | Should Be (
            Get-LongRunGatewayMutexName ($stateDirectory.ToUpperInvariant() + '\'))
        $process = Get-Process -Id $PID
        Stop-LongRunProcessTree `
            -ProcessId $PID `
            -ExpectedStartTimeUtcTicks ($process.StartTime.ToUniversalTime().Ticks - 1) `
            -ExpectedPath $process.Path | Should Be $false
        (Get-Process -Id $PID -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
    }

    It 'treats unreadable process identity as a mismatch' {
        . (Join-Path $scriptRoot 'LongRun.Common.ps1')
        {
            Test-LongRunProcessIdentity -ProcessId 4 `
                -ExpectedStartTimeUtcTicks 1 `
                -ExpectedPath 'C:\not-the-system-process.exe'
        } | Should Not Throw
        Test-LongRunProcessIdentity -ProcessId 4 `
            -ExpectedStartTimeUtcTicks 1 `
            -ExpectedPath 'C:\not-the-system-process.exe' | Should Be $false
        {
            Stop-LongRunProcessTree -ProcessId 4 `
                -ExpectedStartTimeUtcTicks 1 `
                -ExpectedPath 'C:\not-the-system-process.exe'
        } | Should Not Throw
    }
}
