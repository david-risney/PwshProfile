$ErrorActionPreference = 'Stop'

function Write-HookResult([hashtable]$Result) {
    [Console]::Out.Write(($Result | ConvertTo-Json -Compress -Depth 20))
}

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) {
        Write-HookResult @{}
        exit 0
    }

    $payload = $raw | ConvertFrom-Json
    $toolResult = $payload.toolResult
    $text = if ($toolResult.textResultForLlm -is [string]) {
        [string]$toolResult.textResultForLlm
    } elseif ($toolResult.sessionLog -is [string]) {
        [string]$toolResult.sessionLog
    } else {
        ''
    }
    $match = [regex]::Match(
        $text,
        '(?m)^LONGRUN_REMOTE_URL=(https://\S+)\s*$')
    if (-not $match.Success) {
        Write-HookResult @{}
        exit 0
    }

    $url = $match.Groups[1].Value
    $sessionMatch = [regex]::Match(
        $text,
        '(?m)^Long-running command session:\s*(\S+)\s*$')
    $label = if ($sessionMatch.Success) {
        "Remote session: $($sessionMatch.Groups[1].Value)"
    } else {
        'Remote session'
    }
    $markdownLink = "[$label]($url)"
    Write-HookResult @{
        additionalContext = @"
The PowerShell tool created this long-run remote session link:
$markdownLink
Include this exact Markdown link, rather than a bare URL, in the next user-visible response
so the user can open the session. If other long-run session links were created
during the same turn, include every supplied link. Do not substitute the inventory URL.
"@
    }
} catch {
    Write-HookResult @{}
    exit 0
}
