<#
.SYNOPSIS
    Times a Copilot CLI turn and shows an OS toast when it runs long.

.DESCRIPTION
    Invoked by the turn-toast plugin's hooks:
      * -Phase Start  -> on userPromptSubmitted: records the turn start time.
      * -Phase Stop   -> on agentStop: computes elapsed time and, if it exceeds
                         the threshold, shows a BurntToast notification.

    Design goals:
      * Block the turn as little as possible. The Start phase only writes a tiny
        state file. The Stop phase shows the toast in a DETACHED pwsh process so
        the hook returns immediately (importing BurntToast + showing a toast can
        take ~1s, which we never want to add to turn latency).
      * Never disrupt the turn. All work is wrapped so failures stay silent and
        nothing is written to stdout (hook stdout can be injected as model
        context, so we keep it empty).

    Threshold (seconds) is read from the TURN_TOAST_THRESHOLD_SEC environment
    variable and defaults to 30.

    Copilot writes the hook payload (session_id, cwd, timestamp, ...) as JSON on
    stdin and provides the per-plugin data directory via COPILOT_PLUGIN_DATA.
#>
[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop')]
    [string]$Phase
)

# A hook must never break the turn, so swallow everything.
$ErrorActionPreference = 'SilentlyContinue'

try {
    # --- Identify the session (to keep per-session timing files separate) -----
    $sessionId = 'default'
    try {
        $raw = [Console]::In.ReadToEnd()
        if ($raw) {
            $payload = $raw | ConvertFrom-Json
            if ($payload.session_id) { $sessionId = [string]$payload.session_id }
        }
    } catch { }

    # --- Locate state directory (per-plugin data dir, fall back to TEMP) ------
    $dataDir = $env:COPILOT_PLUGIN_DATA
    if (-not $dataDir) { $dataDir = Join-Path $env:TEMP 'turn-toast' }
    if (-not (Test-Path -LiteralPath $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }

    $safeId = ($sessionId -replace '[^A-Za-z0-9_.-]', '_')
    $stateFile = Join-Path $dataDir "turn-$safeId.txt"

    # ------------------------------------------------------------------ START -
    if ($Phase -eq 'Start') {
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        [System.IO.File]::WriteAllText($stateFile, [string]$nowMs)
        return
    }

    # ------------------------------------------------------------------- STOP -
    if (-not (Test-Path -LiteralPath $stateFile)) { return }

    $startMs = [int64]0
    [void][int64]::TryParse(((Get-Content -LiteralPath $stateFile -Raw)).Trim(), [ref]$startMs)
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    if ($startMs -le 0) { return }

    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $elapsedSec = [math]::Round(($nowMs - $startMs) / 1000.0, 1)

    $threshold = 30
    if ($env:TURN_TOAST_THRESHOLD_SEC) {
        [void][int]::TryParse($env:TURN_TOAST_THRESHOLD_SEC, [ref]$threshold)
    }
    if ($elapsedSec -lt $threshold) { return }

    # Friendly elapsed text.
    if ($elapsedSec -ge 60) {
        $elapsedText = '{0}m {1}s' -f [math]::Floor($elapsedSec / 60), [int]([math]::Round($elapsedSec % 60))
    } else {
        $elapsedText = '{0}s' -f $elapsedSec
    }

    # --- Show the toast in a detached process so the hook returns instantly ---
    $toastScript = @"
try {
  Import-Module BurntToast -ErrorAction Stop
  New-BurntToastNotification -Text 'Copilot CLI', 'Turn finished after $elapsedText'
} catch { }
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($toastScript))

    $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $psExe) { $psExe = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
    if (-not $psExe) { return }

    Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
    ) -ErrorAction SilentlyContinue | Out-Null
} catch { }
