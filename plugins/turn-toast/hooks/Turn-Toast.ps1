<#
.SYNOPSIS
    Times a Copilot CLI turn and shows an OS toast when it runs long.

.DESCRIPTION
    Invoked by the turn-toast plugin's hooks:
      * -Phase Start  -> on userPromptSubmitted: records the turn start time.
      * -Phase Stop   -> on agentStop: computes elapsed time and, if it exceeds
                         the threshold AND the originating terminal is not the
                         foreground window, shows a BurntToast notification.

    Design goals:
      * Block the turn as little as possible. The Start phase only writes a tiny
        state file. The Stop phase shows the toast in a DETACHED pwsh process so
        the hook returns immediately (importing BurntToast + showing a toast can
        take ~1s, which we never want to add to turn latency).
      * Only notify when it's useful. If the user is still looking at the
        terminal that ran the turn, no toast is shown -- the point is to ping
        them only when they've switched away. This foreground check runs inside
        the detached process (at notify time) so it costs the turn nothing.
      * Never disrupt the turn. All work is wrapped so failures stay silent and
        nothing is written to stdout (hook stdout can be injected as model
        context, so we keep it empty).

    Threshold (seconds) is read from the TURN_TOAST_THRESHOLD_SEC environment
    variable and defaults to 60.

    Only fires when Copilot is actually ready for the user's next input:
      * In interactive mode, every over-threshold turn qualifies.
      * In autopilot mode, intermediate stops are suppressed (Copilot will keep
        going); the toast fires only when the task completes, and elapsed time is
        measured from the start of the autonomous run. Mode/completion are read
        from the session's event transcript (transcriptPath).

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

# Walk up the process tree from this hook (which runs inside the Copilot CLI /
# terminal process tree) to the first ancestor that owns a real window. That is
# the terminal window the user launched Copilot from, so clicking the toast can
# bring it back to the foreground. Deterministic and independent of whatever
# window currently has focus.
function Get-TerminalHwnd {
    $procId = $PID
    for ($i = 0; $i -lt 15 -and $procId; $i++) {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
        if (-not $wmi) { break }
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -ne 0) { return [int64]$proc.MainWindowHandle }
        $procId = [int]$wmi.ParentProcessId
    }
    return [int64]0
}

# Build a short, human-friendly label identifying which Copilot session/project
# the turn belonged to, for the toast body. Preference order:
#   1. The session's user-provided name (workspace.yaml user_named: true).
#   2. The git repo (repository slug's name, or git_root leaf).
#   3. The working directory path.
# Reads the session's workspace.yaml (flat key: value) rather than shelling out
# to git, so it stays fast and dependency-free.
function Get-SessionLabel {
    param([string]$SessionId, [string]$Cwd)

    $name = $null; $userNamed = $false; $repo = $null; $gitRoot = $null; $yamlCwd = $null

    # Find the session's workspace.yaml under a plausible .copilot root.
    $wf = $null
    if ($SessionId -and $SessionId -ne 'default') {
        $roots = @()
        if ($env:USERPROFILE) { $roots += (Join-Path $env:USERPROFILE '.copilot') }
        if ($env:COPILOT_PLUGIN_DATA) {
            $roots += (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $env:COPILOT_PLUGIN_DATA)))
        }
        foreach ($r in $roots) {
            if (-not $r) { continue }
            $cand = Join-Path $r "session-state\$SessionId\workspace.yaml"
            if (Test-Path -LiteralPath $cand) { $wf = $cand; break }
        }
    }

    if ($wf) {
        foreach ($line in [System.IO.File]::ReadAllLines($wf)) {
            if     ($line -match '^\s*name:\s*(.+?)\s*$')       { $name = $Matches[1].Trim("'`"") }
            elseif ($line -match '^\s*user_named:\s*(.+?)\s*$') { $userNamed = ($Matches[1].Trim() -eq 'true') }
            elseif ($line -match '^\s*repository:\s*(.+?)\s*$') { $repo = $Matches[1].Trim("'`"") }
            elseif ($line -match '^\s*git_root:\s*(.+?)\s*$')   { $gitRoot = $Matches[1].Trim("'`"") }
            elseif ($line -match '^\s*cwd:\s*(.+?)\s*$')        { $yamlCwd = $Matches[1].Trim("'`"") }
        }
    }
    if (-not $Cwd) { $Cwd = $yamlCwd }

    # 1) Human-provided session name.
    if ($userNamed -and $name) { return $name }

    # 2) Git repo.
    if ($repo)    { return ($repo -split '[\\/]')[-1] }
    if ($gitRoot) { return (Split-Path -Leaf $gitRoot) }
    if ($Cwd) {
        $d = $Cwd
        while ($d) {
            if (Test-Path -LiteralPath (Join-Path $d '.git')) { return (Split-Path -Leaf $d) }
            $parent = Split-Path -Parent $d
            if (-not $parent -or $parent -eq $d) { break }
            $d = $parent
        }
    }

    # 3) Path.
    return $Cwd
}

# Collapse whitespace and clamp a label to $Max chars. For path-like values the
# tail (deepest folder) is more informative, so keep the end; otherwise keep the
# start. Uses a single-character ellipsis.
function Format-Label {
    param([string]$Text, [int]$Max = 40)
    if (-not $Text) { return $Text }
    $Text = ($Text -replace '\s+', ' ').Trim()
    if ($Text.Length -le $Max) { return $Text }
    $ellipsis = [char]0x2026
    if ($Text -match '[\\/]') {
        return $ellipsis + $Text.Substring($Text.Length - ($Max - 1))
    }
    return $Text.Substring(0, $Max - 1) + $ellipsis
}

# Inspect the tail of the session's event transcript to understand the state at
# agentStop time, so we only notify when Copilot is genuinely handing control
# back to the user:
#   * Mode              - current session mode (interactive / plan / autopilot),
#                         from the most recent session.mode_changed.
#   * AutopilotStartMs  - when the current autopilot run began (so a long
#                         autonomous task is timed from its real start, not from
#                         the last auto-injected "keep going" reminder).
#   * LastCompleteMs    - timestamp of the most recent task_complete, used to
#                         tell a genuine finish from a mid-autopilot pause (which
#                         Copilot would auto-continue, and which we suppress).
# Only the last ~250 lines are read, and non-matching lines are filtered by a
# cheap substring test before JSON parsing, so this stays fast.
function Get-StopContext {
    param([string]$TranscriptPath)

    $ctx = [pscustomobject]@{ Mode = 'interactive'; AutopilotStartMs = [int64]0; LastCompleteMs = [int64]0 }
    if (-not $TranscriptPath -or -not (Test-Path -LiteralPath $TranscriptPath)) { return $ctx }

    try {
        $lines = Get-Content -LiteralPath $TranscriptPath -Tail 250 -ErrorAction SilentlyContinue
        foreach ($l in $lines) {
            if ($l -like '*"session.mode_changed"*') {
                try {
                    $o = $l | ConvertFrom-Json
                    if ($o.type -eq 'session.mode_changed' -and $o.data.newMode) {
                        $ctx.Mode = [string]$o.data.newMode
                        if ($o.data.newMode -eq 'autopilot') {
                            $ctx.AutopilotStartMs = [int64]([datetimeoffset]$o.timestamp).ToUnixTimeMilliseconds()
                        }
                    }
                } catch { }
            } elseif ($l -like '*"session.task_complete"*') {
                try {
                    $o = $l | ConvertFrom-Json
                    if ($o.type -eq 'session.task_complete') {
                        $ctx.LastCompleteMs = [int64]([datetimeoffset]$o.timestamp).ToUnixTimeMilliseconds()
                    }
                } catch { }
            }
        }
    } catch { }

    return $ctx
}

try {
    # --- Identify the session (to keep per-session timing files separate) -----
    $sessionId = 'default'
    $payloadCwd = $null
    $payloadTranscript = $null
    try {
        $raw = [Console]::In.ReadToEnd()
        if ($raw) {
            $payload = $raw | ConvertFrom-Json
            if ($payload.session_id) { $sessionId = [string]$payload.session_id }
            if ($payload.cwd) { $payloadCwd = [string]$payload.cwd }
            if ($payload.transcriptPath) { $payloadTranscript = [string]$payload.transcriptPath }
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

    $threshold = 60
    if ($env:TURN_TOAST_THRESHOLD_SEC) {
        [void][int]::TryParse($env:TURN_TOAST_THRESHOLD_SEC, [ref]$threshold)
    }

    # Decide whether this stop is a real "ready for your input" moment, and from
    # when to measure elapsed time. In autopilot Copilot keeps working across
    # many turns, so we notify only when it actually finishes (task_complete) and
    # time the whole autonomous run -- never mid-autopilot.
    $transcript = $payloadTranscript
    if (-not $transcript -and $sessionId -ne 'default') {
        $roots = @()
        if ($env:USERPROFILE) { $roots += (Join-Path $env:USERPROFILE '.copilot') }
        if ($env:COPILOT_PLUGIN_DATA) {
            $roots += (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $env:COPILOT_PLUGIN_DATA)))
        }
        foreach ($r in $roots) {
            if (-not $r) { continue }
            $cand = Join-Path $r "session-state\$sessionId\events.jsonl"
            if (Test-Path -LiteralPath $cand) { $transcript = $cand; break }
        }
    }

    $ctx = Get-StopContext -TranscriptPath $transcript
    $baselineMs = $startMs
    if ($ctx.Mode -eq 'autopilot') {
        $isCompletion = ($ctx.LastCompleteMs -gt 0 -and ($nowMs - $ctx.LastCompleteMs) -le 20000)
        if (-not $isCompletion) { return }   # mid-autopilot pause: Copilot will continue, so stay quiet.
        if ($ctx.AutopilotStartMs -gt 0) { $baselineMs = $ctx.AutopilotStartMs }
    }

    $elapsedSec = [math]::Round(($nowMs - $baselineMs) / 1000.0, 1)
    if ($elapsedSec -lt $threshold) { return }

    # Friendly elapsed text.
    if ($elapsedSec -ge 60) {
        $elapsedText = '{0}m {1}s' -f [math]::Floor($elapsedSec / 60), [int]([math]::Round($elapsedSec % 60))
    } else {
        $elapsedText = '{0}s' -f $elapsedSec
    }

    # --- Resolve pwsh + the terminal window and click handler ----------------
    $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $psExe) { $psExe = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
    if (-not $psExe) { return }

    $hwnd = Get-TerminalHwnd
    $focusScript = Join-Path (Split-Path -Parent $PSCommandPath) 'Focus-Window.ps1'

    # Context label (session name / repo / path) for the toast body, escaped for
    # embedding inside a single-quoted string in the generated script.
    $label = Format-Label (Get-SessionLabel -SessionId $sessionId -Cwd $payloadCwd)
    if ($label) {
        $labelEsc = $label -replace "'", "''"
        $textArg = "'Copilot CLI', '$labelEsc', 'Turn finished after $elapsedText'"
    } else {
        $textArg = "'Copilot CLI', 'Turn finished after $elapsedText'"
    }

    # --- Show the toast in a detached process so the hook returns instantly ---
    # The detached process also (re)registers the custom `turntoast:` URL
    # protocol so the toast's "Focus terminal" button can reactivate $hwnd.
    $toastScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
try {
  # Don't notify if the user is already looking at the terminal that ran the
  # turn -- only toast when they've switched away. Checked here (in the detached
  # process, at notify time) so it costs the turn nothing.
  if ($hwnd -gt 0) {
    Add-Type -Namespace TurnToastFg -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();' -ErrorAction Stop
    if ([TurnToastFg.Win]::GetForegroundWindow() -eq [IntPtr]$hwnd) { return }
  }
} catch { }
try {
  `$cmd = '"$psExe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$focusScript" "%1"'
  `$base = 'HKCU:\Software\Classes\turntoast'
  New-Item -Path `$base -Force | Out-Null
  Set-ItemProperty -Path `$base -Name '(default)' -Value 'URL:Turn Toast'
  Set-ItemProperty -Path `$base -Name 'URL Protocol' -Value ''
  New-Item -Path "`$base\shell\open\command" -Force | Out-Null
  Set-ItemProperty -Path "`$base\shell\open\command" -Name '(default)' -Value `$cmd
} catch { }
try {
  Import-Module BurntToast -ErrorAction Stop
  if ($hwnd -gt 0) {
    `$btn = New-BTButton -Content 'Focus terminal' -ActivationType Protocol -Arguments 'turntoast:$hwnd'
    New-BurntToastNotification -Text $textArg -Button `$btn
  } else {
    New-BurntToastNotification -Text $textArg
  }
} catch { }
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($toastScript))

    Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
    ) -ErrorAction SilentlyContinue | Out-Null
} catch { }
