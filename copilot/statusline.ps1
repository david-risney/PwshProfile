# https://gist.github.com/shanselman/9623ac74888a07ba82f63f5310fda11b
# Example input:
# {"cwd":"C:\\Users\\someone\\copilot","session_id":"3fd513d8-4ca6-4272-872e-2825ff519c94","session_name":null,"transcript_path":"C:\\Users\\someone\\.copilot\\session-state\\3fd513d8-4ca6-4272-872e-2825ff519c94","model":{"id":"claude-opus-4.6","display_name":"claude-opus-4.6 (3x) (medium)"},"workspace":{"current_dir":"C:\\Users\\davris\\PwshProfile\\copilot"},"username":null,"remote":{"connected":false},"version":"1.0.45","cost":{"total_api_duration_ms":0,"total_lines_added":0,"total_lines_removed":0,"total_duration_ms":1473,"total_premium_requests":0},"context_window":{"total_input_tokens":0,"total_output_tokens":0,"total_cache_read_tokens":0,"total_cache_write_tokens":0,"total_reasoning_tokens":0,"total_tokens":0,"context_window_size":200000,"used_percentage":0,"remaining_percentage":100,"remaining_tokens":200000,"last_call_input_tokens":0,"last_call_output_tokens":0,"current_context_tokens":0,"displayed_context_limit":200000,"current_context_used_percentage":0}}

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Format-TokenCount {
    param([Nullable[double]]$Value)

    if ($null -eq $Value) { return '?' }
    if ($Value -ge 1000000) { return ('{0:0.0}m' -f ($Value / 1000000)) }
    if ($Value -ge 1000) { return ('{0:0.0}k' -f ($Value / 1000)) }
    return ([int]$Value).ToString()
}



function Format-Duration {
    param([Nullable[double]]$Milliseconds)

    if ($null -eq $Milliseconds -or $Milliseconds -le 0) { return '00:00:00' }
    $duration = [TimeSpan]::FromMilliseconds($Milliseconds)
    return '{0:00}:{1:00}:{2:00}' -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
}

function New-Gauge {
    param([Nullable[double]]$Percent)

    if ($null -eq $Percent) { return '..........' }
    $bounded = [Math]::Max(0, [Math]::Min(100, [Math]::Round($Percent)))
    $filled = [int][Math]::Floor($bounded / 10)
    return ('#' * $filled) + ('.' * (10 - $filled))
}

function New-Moon {
    param([Nullable[double]]$Percent)

    if ($null -eq $Percent) { return '🌑' }
    $bounded = [Math]::Max(0, [Math]::Min(100, [Math]::Round($Percent)))
    $moons = @( '🌕', '🌖', '🌗', '🌘', '🌑')
    $index = [int][Math]::Floor($bounded / 20)
    $index = [Math]::Min($index, $moons.Count - 1)
    return $moons[$index]
}

$payload = [Console]::In.ReadToEnd()

try {
    $json = $payload | ConvertFrom-Json
} catch {
    [Console]::Write('Copilot status unavailable')
    exit 0
}

$context = $json.context_window
$cost = $json.cost

$currentTokens = if ($null -ne $context.current_context_tokens) { [double]$context.current_context_tokens } else { $null }
$contextLimit   = if ($null -ne $context.displayed_context_limit)   { [double]$context.displayed_context_limit }   else { $null }
$contextPercent = if ($null -ne $context.current_context_used_percentage) {
    [double]$context.current_context_used_percentage
} elseif ($null -ne $context.used_percentage) {
    [double]$context.used_percentage
} else { $null }

$linesAdded   = if ($null -ne $cost.total_lines_added)   { [int]$cost.total_lines_added }   else { 0 }
$linesRemoved = if ($null -ne $cost.total_lines_removed) { [int]$cost.total_lines_removed } else { 0 }

$env:COPILOT_STATUS_CONTEXT = "$(Format-TokenCount $currentTokens)/$(Format-TokenCount $contextLimit)"
$env:COPILOT_STATUS_GAUGE = New-Moon $contextPercent
$env:COPILOT_STATUS_DURATION = Format-Duration $cost.total_duration_ms
$env:COPILOT_STATUS_CHANGES = if ($linesAdded -or $linesRemoved) { "+$linesAdded/-$linesRemoved" } else { '' }
$cwd = if ($json.cwd) { [string]$json.cwd } else { (Get-Location).Path }

$themePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'statusline.omp.json'
$ompOutput = (oh-my-posh print primary --config $themePath --pwd $cwd);
$ompOutput = $ompOutput -join ' ';

# Escape ANSI sequences for printing
# $ompOutput = $ompOutput -replace '\x1b', [char]27;

[Console]::Write($ompOutput);