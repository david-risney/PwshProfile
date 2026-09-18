<#
.SYNOPSIS
    Stop and remove the shared long-run psmux web gateway.
#>
[CmdletBinding()]
param(
    [string]$StateDirectory = $(if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'long-run\mux-gateway'
    } else {
        Join-Path $env:TEMP 'long-run-mux-gateway'
    })
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LongRun.Common.ps1')
$StateDirectory = ConvertTo-LongRunCanonicalPath $StateDirectory

$mutex = [Threading.Mutex]::new(
    $false,
    (Get-LongRunGatewayMutexName $StateDirectory))
$locked = $false
try {
    $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(45))
    if (-not $locked) {
        throw 'Timed out waiting for mux gateway startup to finish.'
    }

    $metadataFile = Join-Path $StateDirectory 'gateway.json'
    if (-not (Test-Path -LiteralPath $metadataFile)) {
        Write-Host 'The long-run mux gateway is not running.'
        return
    }

    $metadata = Get-Content -LiteralPath $metadataFile -Raw | ConvertFrom-Json
    Write-Verbose "Stopping gateway state in '$StateDirectory'."
    Stop-LongRunProcessTree `
        -ProcessId ([int]$metadata.tunnelPid) `
        -ExpectedStartTimeUtcTicks ([long]$metadata.tunnelStartTimeUtcTicks) `
        -ExpectedPath ([string]$metadata.tunnelRunnerPath) | Out-Null
    if ($metadata.gatewaySession -and $metadata.psmuxPath) {
        Write-Verbose "Stopping psmux session '$($metadata.gatewaySession)'."
        try {
            Stop-LongRunPsmuxSession `
                -PsmuxPath ([string]$metadata.psmuxPath) `
                -Session ([string]$metadata.gatewaySession) `
                -ExpectedCreated ([long]$metadata.gatewaySessionCreated) `
                -ExpectedId ([string]$metadata.gatewaySessionId) | Out-Null
        } catch {
            Write-Verbose "Could not stop the psmux session directly: $($_.Exception.Message)"
        }
    }
    Stop-LongRunProcessTree `
        -ProcessId ([int]$metadata.gatewayPid) `
        -ExpectedStartTimeUtcTicks ([long]$metadata.gatewayStartTimeUtcTicks) `
        -ExpectedPath ([string]$metadata.gatewayRunnerPath) | Out-Null
    if ($metadata.tunnelId -and $metadata.devTunnelPath) {
        & $metadata.devTunnelPath delete $metadata.tunnelId -f 2>$null | Out-Null
    }
    Remove-Item -LiteralPath $StateDirectory -Recurse -Force
    Write-Host 'The long-run mux gateway and dev tunnel were removed.'
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
