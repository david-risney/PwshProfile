<#
.SYNOPSIS
    Ensure the shared long-run psmux web gateway is running.

.DESCRIPTION
    Starts one localhost Node reverse proxy and, unless -LocalOnly is supplied,
    one authenticated dev tunnel. The proxy lists named psmux sessions under
    /tmux/ and starts an ephemeral ttyd process only when a session URL is opened.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$TunnelExpirationDays = 30,

    [ValidateRange(10, 3600)]
    [int]$TerminalStartupIdleSeconds = 120,

    [ValidateRange(1, 3600)]
    [int]$TerminalDisconnectIdleSeconds = 2,

    [string]$TerminalFontFamily = '"Long Run Nerd Font", "CaskaydiaCove NFM", "CaskaydiaCove NF", "Cascadia Mono", Consolas, monospace',

    [string]$TerminalFontPath,

    [string]$ShellPath,

    [ValidateRange(0, 65535)]
    [int]$Port = 0,

    [switch]$LocalOnly,

    [switch]$AllowAnonymous,

    [string]$StateDirectory = $(if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'long-run\mux-gateway'
    } else {
        Join-Path $env:TEMP 'long-run-mux-gateway'
    }),

    [string]$GatewaySource = (Join-Path (Split-Path -Parent $PSScriptRoot) 'gateway'),

    [string]$PsmuxPath,

    [string]$TtydPath,

    [string]$DevTunnelPath,

    [string]$NodePath,

    [string]$NpmPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LongRun.Common.ps1')
$StateDirectory = ConvertTo-LongRunCanonicalPath $StateDirectory
$defaultWorkingDirectory = if ($env:USERPROFILE) {
    $env:USERPROFILE
} else {
    $PWD.Path
}

function Test-GatewayHealth([int]$Port, [string]$Capability) {
    if (-not $Capability) { return $false }
    try {
        $response = Invoke-RestMethod "http://127.0.0.1:$Port/healthz" `
            -Headers @{ 'X-Long-Run-Capability' = $Capability } `
            -TimeoutSec 2
        return $response.status -eq 'ok'
    } catch {
        return $false
    }
}

function Write-GatewayMetadata([string]$Path, [object]$Value) {
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            ($Value | ConvertTo-Json -Compress),
            [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-GatewayStateDirectory {
    if (-not (Test-Path -LiteralPath $StateDirectory)) { return }
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            Remove-Item -LiteralPath $StateDirectory -Recurse -Force `
                -ErrorAction Stop
            return
        } catch [System.IO.IOException] {
            if ($attempt -eq 49) { throw }
        } catch [System.UnauthorizedAccessException] {
            if ($attempt -eq 49) { throw }
        }
        Start-Sleep -Milliseconds 100
    }
}

function ConvertFrom-LongRunNativeJson([object[]]$Output, [string]$CommandName) {
    $text = (@($Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    $match = [regex]::Match($text, '(?s)\{.*\}')
    if (-not $match.Success) {
        throw "$CommandName did not return a JSON object."
    }
    return $match.Value | ConvertFrom-Json
}

function Resolve-TerminalFontPath([string]$RequestedPath) {
    if ($RequestedPath) {
        return (Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop).Path
    }
    $fontNames = @(
        'CaskaydiaCoveNerdFontMono-Regular.ttf',
        'CaskaydiaCoveNerdFont-Regular.ttf'
    )
    $fontRoots = @(
        $(if ($env:LOCALAPPDATA) {
            Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        }),
        $(if ($env:WINDIR) {
            Join-Path $env:WINDIR 'Fonts'
        })
    ) | Where-Object { $_ }
    foreach ($root in $fontRoots) {
        foreach ($name in $fontNames) {
            $candidate = Join-Path $root $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    return $null
}

function Remove-StaleGateway {
    param([object]$Metadata)

    if ($Metadata) {
        if ($Metadata.gatewaySession) {
            Write-Verbose "Stopping stale gateway session '$($Metadata.gatewaySession)'."
            try {
                Stop-LongRunPsmuxSession `
                    -PsmuxPath $(if ($Metadata.psmuxPath) {
                        [string]$Metadata.psmuxPath
                    } else {
                        $PsmuxPath
                    }) `
                    -Session ([string]$Metadata.gatewaySession) `
                    -ExpectedCreated ([long]$Metadata.gatewaySessionCreated) `
                    -ExpectedId ([string]$Metadata.gatewaySessionId) |
                    Out-Null
            } catch {
                Write-Verbose "Could not stop the psmux session directly: $($_.Exception.Message)"
            }
        }
        Stop-LongRunProcessTree `
            -ProcessId ([int]$Metadata.tunnelPid) `
            -ExpectedStartTimeUtcTicks ([long]$Metadata.tunnelStartTimeUtcTicks) `
            -ExpectedPath ([string]$Metadata.tunnelRunnerPath) | Out-Null
        Stop-LongRunProcessTree `
            -ProcessId ([int]$Metadata.gatewayPid) `
            -ExpectedStartTimeUtcTicks ([long]$Metadata.gatewayStartTimeUtcTicks) `
            -ExpectedPath ([string]$Metadata.gatewayRunnerPath) | Out-Null
        if ($Metadata.tunnelId -and $Metadata.devTunnelPath) {
            & $Metadata.devTunnelPath delete $Metadata.tunnelId -f 2>$null |
                Out-Null
        }
    }
    Remove-GatewayStateDirectory
}

function New-LongRunCapability {
    $bytes = New-Object byte[] 24
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    } finally {
        $random.Dispose()
    }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$mutexName = Get-LongRunGatewayMutexName $StateDirectory
$mutex = [Threading.Mutex]::new($false, $mutexName)
$locked = $false
try {
    Write-LongRunLog -Component 'gateway-launcher' -Event 'start-requested' `
        -Data @{ localOnly = [bool]$LocalOnly }
    $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(45))
    if (-not $locked) {
        throw 'Timed out waiting for another mux gateway startup to finish.'
    }
    Write-Verbose "Acquired gateway startup lock for '$StateDirectory'."

    $PsmuxPath = Resolve-LongRunCommandPath $PsmuxPath @('psmux', 'pmux') `
        'Install it with: winget install --id marlocarlo.psmux'
    $TtydPath = Resolve-LongRunCommandPath $TtydPath @('ttyd') `
        'Install it with: winget install --id tsl0922.ttyd'
    if (-not $LocalOnly) {
        $DevTunnelPath = Resolve-LongRunCommandPath $DevTunnelPath @('devtunnel') `
            'Install it with: winget install --id Microsoft.devtunnel'
    }
    $NodePath = Resolve-LongRunCommandPath $NodePath @('node') `
        'Install a supported Node.js release.'
    $NpmPath = Resolve-LongRunCommandPath $NpmPath @('npm.cmd', 'npm') `
        'Install npm with Node.js.'
    $ShellPath = Resolve-LongRunShellPath $ShellPath
    $TerminalFontPath = Resolve-TerminalFontPath $TerminalFontPath
    if (-not $TerminalFontPath) {
        Write-Warning 'No CaskaydiaCove Nerd Font file was found. Use -TerminalFontPath to provide one.'
    }
    $GatewaySource = (Resolve-Path -LiteralPath $GatewaySource).Path
    $gatewayPackage = Get-Content (Join-Path $GatewaySource 'package.json') -Raw |
        ConvertFrom-Json
    $gatewayVersion = [string]$gatewayPackage.version
    if (-not $gatewayVersion) {
        throw 'The mux gateway package does not declare a version.'
    }
    Write-Verbose "Using psmux '$PsmuxPath'."
    Write-Verbose "Using ttyd '$TtydPath'."
    Write-Verbose "Using Node.js '$NodePath' and npm '$NpmPath'."
    Write-Verbose "Using '$ShellPath' for sessions created from the web UI."
    Write-Verbose "Using '$defaultWorkingDirectory' as the web UI's default CWD."
    Write-Verbose "Using gateway source '$GatewaySource' (version $gatewayVersion)."
    if ($TerminalFontPath) {
        Write-Verbose "Serving terminal font '$TerminalFontPath'."
    }
    $sourceHashText = @(
        (Get-FileHash (Join-Path $GatewaySource 'server.js') -Algorithm SHA256).Hash
        (Get-FileHash (Join-Path $GatewaySource 'app.js') -Algorithm SHA256).Hash
        (Get-FileHash (Join-Path $GatewaySource 'package.json') -Algorithm SHA256).Hash
        (Get-FileHash (Join-Path $GatewaySource 'package-lock.json') -Algorithm SHA256).Hash
        (Get-FileHash (Join-Path $GatewaySource '.npmrc') -Algorithm SHA256).Hash
    ) -join ':'
    $configurationText = @(
        $sourceHashText
        $PsmuxPath
        $TtydPath
        $DevTunnelPath
        $NodePath
        $NpmPath
        $ShellPath
        $TerminalStartupIdleSeconds
        $TerminalDisconnectIdleSeconds
        $TerminalFontFamily
        $TerminalFontPath
        $(if ($TerminalFontPath) {
            (Get-FileHash $TerminalFontPath -Algorithm SHA256).Hash
        })
        $defaultWorkingDirectory
        $Port
        [bool]$LocalOnly
        $TunnelExpirationDays
        [bool]$AllowAnonymous
        (Get-LongRunGatewayLogPath $StateDirectory)
    ) -join "`n"
    $configurationFingerprint = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($configurationText)))

    $metadataFile = Join-Path $StateDirectory 'gateway.json'
    $metadata = $null
    if (Test-Path -LiteralPath $metadataFile) {
        try {
            $metadata = Get-Content -LiteralPath $metadataFile -Raw |
                ConvertFrom-Json
        } catch { }
    }
    $requiredProcessesHealthy = $false
    $gatewayHealthy = $false
    if ($metadata) {
        try {
            $requiredProcessesHealthy = if ($LocalOnly) {
                $true
            } else {
                Test-LongRunProcessIdentity `
                    -ProcessId ([int]$metadata.tunnelPid) `
                    -ExpectedStartTimeUtcTicks ([long]$metadata.tunnelStartTimeUtcTicks) `
                    -ExpectedPath ([string]$metadata.tunnelRunnerPath)
            }
            $gatewayHealthy = if ($metadata.gatewaySession) {
                [bool](Get-LongRunPsmuxSessions $PsmuxPath |
                    Where-Object {
                        $_.Name -eq [string]$metadata.gatewaySession -and
                        $_.Created -eq [long]$metadata.gatewaySessionCreated -and
                        $_.Id -eq [string]$metadata.gatewaySessionId
                    })
            } else {
                Test-LongRunProcessIdentity `
                    -ProcessId ([int]$metadata.gatewayPid) `
                    -ExpectedStartTimeUtcTicks ([long]$metadata.gatewayStartTimeUtcTicks) `
                    -ExpectedPath ([string]$metadata.gatewayRunnerPath)
            }
        } catch {
            Write-Verbose "Existing gateway metadata is incomplete or invalid: $($_.Exception.Message)"
            $requiredProcessesHealthy = $false
            $gatewayHealthy = $false
        }
    }
    if ($metadata -and
        $metadata.configurationFingerprint -eq $configurationFingerprint -and
        $metadata.url -and
        ($metadata.localOnly -or $metadata.tunnelId) -and
        $gatewayHealthy -and
        $requiredProcessesHealthy -and
        (Test-GatewayHealth ([int]$metadata.port) ([string]$metadata.terminalCapability))) {
        Write-LongRunLog -Component 'gateway-launcher' -Event 'reused' `
            -Data @{ localOnly = [bool]$LocalOnly; port = [int]$metadata.port }
        Write-Verbose "Reusing gateway session '$($metadata.gatewaySession)' on port $($metadata.port)."
        Write-Output ([pscustomobject]@{
            Url = "$($metadata.url.TrimEnd('/'))/tmux/?accessToken=$(
                [uri]::EscapeDataString([string]$metadata.terminalCapability))"
            BaseUrl = $metadata.url.TrimEnd('/')
            Port = [int]$metadata.port
            TunnelId = [string]$metadata.tunnelId
            GatewayPid = [int]$metadata.gatewayPid
            GatewaySession = [string]$metadata.gatewaySession
            TunnelPid = [int]$metadata.tunnelPid
            TerminalCapability = [string]$metadata.terminalCapability
            Reused = $true
        })
        return
    }

    if ($metadata) {
        Write-Verbose 'Existing gateway state is stale or its configuration changed; replacing it.'
    }
    Remove-StaleGateway $metadata
    New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null

    $appDirectory = Join-Path $StateDirectory 'app'
    New-Item -ItemType Directory -Path $appDirectory | Out-Null
    Copy-Item -LiteralPath (Join-Path $GatewaySource 'server.js') `
        -Destination $appDirectory
    Copy-Item -LiteralPath (Join-Path $GatewaySource 'app.js') `
        -Destination $appDirectory
    Copy-Item -LiteralPath (Join-Path $GatewaySource 'package.json') `
        -Destination $appDirectory
    Copy-Item -LiteralPath (Join-Path $GatewaySource 'package-lock.json') `
        -Destination $appDirectory
    Copy-Item -LiteralPath (Join-Path $GatewaySource '.npmrc') `
        -Destination $appDirectory
    Write-Verbose "Installing production gateway dependencies in '$appDirectory'."
    & $NpmPath ci --omit=dev --ignore-scripts --prefix $appDirectory `
        --no-audit --no-fund | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'npm failed to install the mux gateway dependencies.'
    }

    $port = if ($Port -gt 0) { $Port } else { Get-LongRunFreeTcpPort }
    $terminalCapability = New-LongRunCapability
    Write-Verbose "Selected loopback port $port."
    $configFile = Join-Path $StateDirectory 'config.json'
    $config = [ordered]@{
        bindHost = '127.0.0.1'
        port = $port
        stateDirectory = $StateDirectory
        psmux = $PsmuxPath
        ttyd = $TtydPath
        shell = $ShellPath
        version = $gatewayVersion
        defaultWorkingDirectory = $defaultWorkingDirectory
        terminalStartupIdleSeconds = $TerminalStartupIdleSeconds
        terminalDisconnectIdleSeconds = $TerminalDisconnectIdleSeconds
        terminalFontFamily = $TerminalFontFamily
        terminalFontPath = $TerminalFontPath
        terminalCapability = $terminalCapability
        logPath = Get-LongRunGatewayLogPath $StateDirectory
    }
    [System.IO.File]::WriteAllText(
        $configFile,
        ($config | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false))

    $gatewayPid = 0
    $gatewaySession = $null
    $gatewaySessionCreated = 0
    $gatewaySessionId = $null
    $tunnelPid = 0
    $tunnelId = $null
    try {
        Write-Verbose 'Starting the gateway in a long-run-util-gateway-{N} psmux session.'
        $gatewayService = Start-LongRunPsmuxService `
            -PsmuxPath $PsmuxPath `
            -SessionPrefix 'long-run-util-gateway' `
            -FilePath $NodePath `
            -Arguments @((Join-Path $appDirectory 'server.js'), $configFile) `
            -StateDirectory $StateDirectory `
            -WorkingDirectory $appDirectory
        $gatewayPid = $gatewayService.ProcessId
        $gatewaySession = $gatewayService.Session
        $gatewaySessionCreated = $gatewayService.SessionCreated
        $gatewaySessionId = $gatewayService.SessionId
        $metadata = [ordered]@{
            gatewaySession = $gatewaySession
            gatewaySessionCreated = $gatewaySessionCreated
            gatewaySessionId = $gatewaySessionId
            psmuxPath = $PsmuxPath
            configurationFingerprint = $configurationFingerprint
            devTunnelPath = $DevTunnelPath
            localOnly = [bool]$LocalOnly
            allowAnonymous = [bool]$AllowAnonymous
            startedAt = [DateTimeOffset]::UtcNow.ToString('o')
            terminalCapability = $terminalCapability
        }
        Write-GatewayMetadata $metadataFile $metadata
        Write-Verbose "Started gateway session '$gatewaySession' (runner PID $gatewayPid)."
        Write-Verbose "Attach with: & '$PsmuxPath' attach-session -t '$gatewaySession'"
        Wait-LongRunTcpPort $port
        if (-not (Test-GatewayHealth $port $terminalCapability)) {
            throw 'The mux gateway did not pass its health check.'
        }
        Write-Verbose "Gateway health check passed at http://127.0.0.1:$port/healthz."
        $gatewayProcess = Get-Process -Id $gatewayPid
        $gatewayRunnerPath = $gatewayProcess.Path
        $gatewayStartTimeUtcTicks =
            $gatewayProcess.StartTime.ToUniversalTime().Ticks
        $metadata['port'] = $port
        $metadata['gatewayPid'] = $gatewayPid
        $metadata['gatewayStartTimeUtcTicks'] = $gatewayStartTimeUtcTicks
        $metadata['gatewayRunnerPath'] = $gatewayRunnerPath
        Write-GatewayMetadata $metadataFile $metadata

        if ($LocalOnly) {
            $baseUrl = "http://127.0.0.1:$port"
            $metadata['url'] = $baseUrl
            Write-GatewayMetadata $metadataFile $metadata
            Write-LongRunLog -Component 'gateway-launcher' -Event 'started' `
                -Data @{ localOnly = $true; port = $port; gatewayPid = $gatewayPid }
            Write-Output ([pscustomobject]@{
                Url = "$baseUrl/tmux/?accessToken=$(
                    [uri]::EscapeDataString($terminalCapability))"
                BaseUrl = $baseUrl
                Port = $port
                TunnelId = $null
                GatewayPid = $gatewayPid
                GatewaySession = $gatewaySession
                TunnelPid = $null
                TerminalCapability = $terminalCapability
                Reused = $false
            })
            return
        }

        $tunnelName = 'lr-mux-{0}' -f (
            [guid]::NewGuid().ToString('N').Substring(0, 12))
        Write-Verbose "Creating dev tunnel '$tunnelName' for port $port."
        $createArgs = @(
            'create', $tunnelName,
            '-e', "${TunnelExpirationDays}d",
            '-d', 'long-run psmux gateway',
            '-j'
        )
        if ($AllowAnonymous) { $createArgs += '--allow-anonymous' }
        $createOutput = @(& $DevTunnelPath @createArgs)
        if ($LASTEXITCODE -ne 0) {
            throw 'devtunnel failed to create the mux gateway tunnel.'
        }
        $created = ConvertFrom-LongRunNativeJson $createOutput 'devtunnel create'
        if (-not $created.tunnel.tunnelId) {
            throw 'devtunnel failed to create the mux gateway tunnel.'
        }
        $tunnelId = [string]$created.tunnel.tunnelId
        $metadata['tunnelId'] = $tunnelId
        Write-GatewayMetadata $metadataFile $metadata

        $portOutput = @(
            & $DevTunnelPath port create $tunnelId -p $port --protocol http `
                --host-header unchanged --origin-header unchanged -j
        )
        if ($LASTEXITCODE -ne 0) {
            throw 'devtunnel failed to register the mux gateway port.'
        }
        ConvertFrom-LongRunNativeJson $portOutput 'devtunnel port create' | Out-Null

        $tunnelPid = Start-LongRunDetachedService `
            -Name 'devtunnel' `
            -FilePath $DevTunnelPath `
            -Arguments @('host', $tunnelId) `
            -StateDirectory $StateDirectory
        Write-Verbose "Started dev tunnel host runner PID $tunnelPid."
        $tunnelProcess = Get-Process -Id $tunnelPid
        $tunnelStartTimeUtcTicks =
            $tunnelProcess.StartTime.ToUniversalTime().Ticks
        $metadata['tunnelPid'] = $tunnelPid
        $metadata['tunnelStartTimeUtcTicks'] = $tunnelStartTimeUtcTicks
        $metadata['tunnelRunnerPath'] = $tunnelProcess.Path
        Write-GatewayMetadata $metadataFile $metadata

        $baseUrl = Wait-LongRunTunnelUrl `
            -ProcessId $tunnelPid `
            -LogFiles @(
                (Join-Path $StateDirectory 'devtunnel.out.log'),
                (Join-Path $StateDirectory 'devtunnel.err.log'))
        Write-Verbose "Dev tunnel is available at '$baseUrl'."
        $metadata['url'] = $baseUrl
        Write-GatewayMetadata $metadataFile $metadata
        Write-LongRunLog -Component 'gateway-launcher' -Event 'started' `
            -Data @{
                localOnly = $false
                port = $port
                gatewayPid = $gatewayPid
                tunnelPid = $tunnelPid
            }
        Write-Output ([pscustomobject]@{
            Url = "$baseUrl/tmux/?accessToken=$(
                [uri]::EscapeDataString($terminalCapability))"
            BaseUrl = $baseUrl
            Port = $port
            TunnelId = $tunnelId
            GatewayPid = $gatewayPid
            GatewaySession = $gatewaySession
            TunnelPid = $tunnelPid
            TerminalCapability = $terminalCapability
            Reused = $false
        })
    } catch {
        Write-LongRunLog -Component 'gateway-launcher' -Event 'start-failed' `
            -Level 'error' -Data @{ errorType = $_.Exception.GetType().FullName }
        if ($tunnelPid -gt 0) {
            $tunnelProcess = Get-Process -Id $tunnelPid -ErrorAction SilentlyContinue
            Stop-LongRunProcessTree `
                -ProcessId $tunnelPid `
                -ExpectedStartTimeUtcTicks $(if ($tunnelProcess) {
                    $tunnelProcess.StartTime.ToUniversalTime().Ticks
                }) `
                -ExpectedPath $(if ($tunnelProcess) { $tunnelProcess.Path }) |
                Out-Null
        }
        if ($gatewaySession) {
            Stop-LongRunPsmuxSession -PsmuxPath $PsmuxPath `
                -Session $gatewaySession `
                -ExpectedCreated $gatewaySessionCreated `
                -ExpectedId $gatewaySessionId | Out-Null
        }
        if ($tunnelId) {
            & $DevTunnelPath delete $tunnelId -f 2>$null | Out-Null
        }
        Remove-Item -LiteralPath $StateDirectory -Recurse -Force `
            -ErrorAction SilentlyContinue
        throw
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
