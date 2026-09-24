$ErrorActionPreference = 'Stop'

function Write-HookResult([hashtable]$Result) {
    [Console]::Out.Write(($Result | ConvertTo-Json -Compress -Depth 20))
}

function Test-ExplicitOptOut([string]$Command) {
    if ($env:COPILOT_PSMUX -eq '0') { return $true }
    return $Command -match '(?i)(?:COPILOT_PSMUX\s*=\s*[''"]?0|\$env:COPILOT_PSMUX\s*=\s*[''"]0[''"])'
}

function Test-PsmuxCommand([string]$Command) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Command,
        [ref]$tokens,
        [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        return $true
    }
    $commands = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true))
    foreach ($commandAst in $commands) {
        $commandName = $commandAst.GetCommandName()
        if (-not $commandName -and $commandAst.CommandElements.Count -gt 0) {
            $commandName =
                $commandAst.CommandElements[0].Extent.Text.Trim("'`"")
        }
        if (-not $commandName) { continue }
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension(
            $commandName.TrimStart('$'))
        if ($leaf -match '^(?i:psmux|pmux|tmux)(?:path)?$') {
            return $true
        }
    }
    return $false
}

function Test-PsmuxAvailable {
    if (Get-Command psmux, pmux -ErrorAction SilentlyContinue |
        Select-Object -First 1) {
        return $true
    }
    if ($env:LOCALAPPDATA) {
        return Test-Path -LiteralPath (
            Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\psmux.exe') `
            -PathType Leaf
    }
    return $false
}

function Test-ExactOutput([pscustomobject]$ToolArgs, [string]$Command) {
    if ($env:COPILOT_PSMUX_EXACT_OUTPUT -eq '1') { return $true }
    if ($ToolArgs.description -match '(?i)\b(binary|byte stream|exact bytes?|machine-readable)\b') {
        return $true
    }
    return $Command -match '(?ix)
        (?:^|\s)-AsByteStream(?:\s|$) |
        (?:^|\s)-Encoding\s+Byte(?:\s|$) |
        \[Console\]::OpenStandard(?:Output|Error) |
        \bConvertTo-Json\b |
        (?:^|\s)--json(?:\s|=|$) |
        (?:^|\s)-(?:json|raw)(?:\s|$)
    '
}

function Get-LongRunTerminalCommandType([string]$Command) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $Command,
        [ref]$tokens,
        [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        return $null
    }
    $lastStatement = @($ast.EndBlock.Statements |
        Select-Object -Last 1)[0]
    if (-not $lastStatement) {
        return 'PowerShell'
    }
    if ($lastStatement -is
        [Management.Automation.Language.ExitStatementAst]) {
        return 'ExplicitExit'
    }
    if ($lastStatement -isnot
        [Management.Automation.Language.PipelineAst]) {
        return $null
    }
    $terminalCommand = @($lastStatement.PipelineElements |
        Where-Object {
            $_ -is [Management.Automation.Language.CommandAst]
        } |
        Select-Object -Last 1)[0]
    if (-not $terminalCommand) {
        return 'PowerShell'
    }

    $commandName = $terminalCommand.GetCommandName()
    if (-not $commandName -and
        $terminalCommand.CommandElements.Count -gt 0) {
        $commandText = $terminalCommand.CommandElements[0].Extent.Text.Trim()
        if ($commandText -match '^\$env:([A-Za-z_][A-Za-z0-9_]*)$') {
            $commandName = [Environment]::GetEnvironmentVariable($Matches[1])
        } elseif ($commandText -match '^[''"](.+)[''"]$') {
            $commandName = $Matches[1]
        }
    }
    if (-not $commandName) {
        return $null
    }
    $resolved = Get-Command $commandName -ErrorAction SilentlyContinue |
        Select-Object -First 1
    while ($resolved -and $resolved.CommandType -eq 'Alias' -and
        $resolved.ResolvedCommand) {
        $resolved = $resolved.ResolvedCommand
    }
    if (-not $resolved) {
        return $null
    }
    if ($resolved.CommandType -in @('Application', 'ExternalScript')) {
        return 'Native'
    }
    return 'PowerShell'
}

try {
    $pluginRoot = Split-Path -Parent $PSScriptRoot
    $common = Join-Path $pluginRoot 'skills\long-run\scripts\LongRun.Common.ps1'
    . $common
    $tempRoot = Join-Path $env:TEMP 'long-run-hook'
    if (Test-Path -LiteralPath $tempRoot) {
        Get-ChildItem -LiteralPath $tempRoot -Filter 'command-*.ps1' -File |
            Where-Object LastWriteTimeUtc -LT ([DateTime]::UtcNow.AddHours(-24)) |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) {
        Write-LongRunLog -Component 'hook' -Event 'skipped' `
            -Data @{ reason = 'empty-payload' }
        Write-HookResult @{}
        exit 0
    }
    $payload = $raw | ConvertFrom-Json
    $toolArgs = $payload.toolArgs
    if ($toolArgs -is [string]) {
        try {
            $toolArgs = $toolArgs | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-LongRunLog -Component 'hook' -Event 'skipped' `
                -Data @{ reason = 'malformed-serialized-tool-arguments' }
            Write-HookResult @{}
            exit 0
        }
    }
    if (-not $toolArgs -or -not ($toolArgs.command -is [string])) {
        Write-LongRunLog -Component 'hook' -Event 'skipped' `
            -Data @{ reason = 'unsupported-tool-arguments' }
        Write-HookResult @{}
        exit 0
    }

    $command = [string]$toolArgs.command
    $terminalCommandType = Get-LongRunTerminalCommandType $command
    $isBackground = ($toolArgs.mode -eq 'async') -or ($toolArgs.detach -eq $true)
    $skipReason = if ($env:PSMUX_SESSION) {
        'nested-psmux'
    } elseif (Test-PsmuxCommand $command) {
        'psmux-command'
    } elseif ($isBackground) {
        'background'
    } elseif (Test-ExactOutput $toolArgs $command) {
        'exact-output'
    } elseif (Test-ExplicitOptOut $command) {
        'explicit-opt-out'
    } elseif (-not $terminalCommandType) {
        'unsupported-exit-propagation'
    } elseif (-not (Test-PsmuxAvailable)) {
        'psmux-unavailable'
    } else {
        $null
    }
    if ($skipReason) {
        Write-LongRunLog -Component 'hook' -Event 'skipped' `
            -Data @{ reason = $skipReason }
        Write-HookResult @{}
        exit 0
    }

    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    $commandFile = Join-Path $tempRoot ("command-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    $successVariable = '__longRunCommandSucceeded_' +
        [guid]::NewGuid().ToString('N')
    $commandWithExitPropagation = @(
        $command
        "`$$successVariable = `$?"
        '$__longRunNativeExitCode = $LASTEXITCODE'
        $(if ($terminalCommandType -eq 'Native') {
            "if (-not `$$successVariable -and " +
                "`$__longRunNativeExitCode -is [int] -and " +
                "`$__longRunNativeExitCode -ne 0) { " +
                'exit $__longRunNativeExitCode }'
        })
        "if (-not `$$successVariable) { exit 1 }"
        'exit 0'
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText(
        $commandFile,
        $commandWithExitPropagation,
        [System.Text.UTF8Encoding]::new($false))

    $runner = Join-Path $pluginRoot 'skills\long-run\scripts\Start-LongRun.ps1'
    $cwd = if ($payload.cwd) { [string]$payload.cwd } else { (Get-Location).Path }
    $session = Get-LongRunCommandSessionName $command
    $remoteMode = if (Test-LongRunRemoteSession) { 'Always' } else { 'Never' }
    $quote = {
        param([string]$Value)
        ConvertTo-LongRunPowerShellLiteral $Value
    }
    $wrapped = "try { & $(& $quote $runner) -CommandFile $(& $quote $commandFile) -RemoveCommandFile " +
        "-WorkingDirectory $(& $quote $cwd) -Session $(& $quote $session) " +
        "-RemoteMode $remoteMode -NoViewer } finally { Remove-Item -LiteralPath " +
        "$(& $quote $commandFile) -Force -ErrorAction SilentlyContinue }; exit `$LASTEXITCODE"

    $modified = [ordered]@{}
    foreach ($property in $toolArgs.PSObject.Properties) {
        $modified[$property.Name] = $property.Value
    }
    $modified.command = $wrapped
    $modified.mode = 'sync'
    $modified.Remove('detach')

    Write-LongRunLog -Component 'hook' -Event 'wrapped' -Session $session `
        -Data @{ remote = ($remoteMode -eq 'Always'); cwd = $cwd }
    Write-HookResult @{ modifiedArgs = $modified }
} catch {
    # preToolUse command hooks fail closed on non-zero exit. Parsing or local
    # setup trouble must leave the original tool call untouched instead.
    try {
        if (Get-Command Write-LongRunLog -ErrorAction SilentlyContinue) {
            Write-LongRunLog -Component 'hook' -Event 'failed-open' -Level 'warning' `
                -Data @{ errorType = $_.Exception.GetType().FullName }
        }
    } catch { }
    Write-HookResult @{}
    exit 0
}
