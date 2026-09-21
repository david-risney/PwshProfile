<#
.SYNOPSIS
    Run opt-in long-run tests against real local dependencies.

.DESCRIPTION
    The regular Pester suite uses fakes and remains fast. This runner enables
    selected groups in LongRun.Integration.Tests.ps1:

    Core              Real psmux lifecycle, secondary input, owner cleanup,
                      concurrent commands, and complete high-volume output.
    Browser           Real localhost gateway -> WebSocket -> ttyd -> psmux input.
    UI                Opens a real local terminal viewer and checks two clients.
    Copilot           Real isolated copilot --plugin-dir hook trial.
    KnownLimitations  Probes Ctrl+C delivery. This is expected to fail with
                      psmux 3.3.8.
#>
[CmdletBinding()]
param(
    [ValidateSet('Core', 'Browser', 'UI', 'Copilot', 'KnownLimitations', 'All')]
    [string[]]$Group = @('Core')
)

$ErrorActionPreference = 'Stop'
$testPath = Join-Path $PSScriptRoot 'LongRun.Integration.Tests.ps1'
$names = @(
    'LONG_RUN_INTEGRATION',
    'LONG_RUN_BROWSER_INTEGRATION',
    'LONG_RUN_UI_INTEGRATION',
    'LONG_RUN_COPILOT_INTEGRATION',
    'LONG_RUN_KNOWN_LIMIT_INTEGRATION')
$saved = @{}
foreach ($name in $names) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}

try {
    $all = $Group -contains 'All'
    if ($all -or $Group -contains 'Core') {
        $env:LONG_RUN_INTEGRATION = '1'
    }
    if ($all -or $Group -contains 'Browser') {
        $env:LONG_RUN_BROWSER_INTEGRATION = '1'
    }
    if ($all -or $Group -contains 'UI') {
        $env:LONG_RUN_UI_INTEGRATION = '1'
    }
    if ($all -or $Group -contains 'Copilot') {
        $env:LONG_RUN_COPILOT_INTEGRATION = '1'
    }
    if ($all -or $Group -contains 'KnownLimitations') {
        $env:LONG_RUN_KNOWN_LIMIT_INTEGRATION = '1'
    }

    $result = Invoke-Pester -Script $testPath -PassThru
    if ($result.FailedCount -gt 0) { exit 1 }
} finally {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable(
            $name, $saved[$name], 'Process')
    }
}
