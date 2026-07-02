#requires -Version 7
<#
    psmux-picker.ps1 — themed action + tab/pane picker.

    Rendered inside a psmux `display-popup` (bound to Prefix + w). The popup's
    rounded bright-green border comes from the global popup-* options in
    psmux.conf; everything inside this script is styled with truecolor ANSI so
    it matches the oh-my-posh / statusline / zellij "davris" palette.

    It lists the live windows (tabs) and panes of the current session, lets you
    jump to any of them by number, and offers the New-tab / New-pane / Zoom /
    Rename / Close actions that choose-tree can't host.

    -Choice lets tests drive a selection non-interactively; normally the script
    prompts for a key.
#>
param(
    [string]$Choice
)

$ESC = [char]27

# ---- palette (R;G;B for truecolor ANSI) ----
$C = @{
    darkfg = '8;35;54'
    lightfg = '224;224;224'
    dim    = '138;138;158'
    green  = '0;255;136'
    blue   = '0;191;255'
    purple = '206;94;254'
    yellow = '255;250;106'
    orange = '255;181;106'
    pink   = '255;112;146'
    cyan   = '0;229;229'
}

function FG([string]$rgb, [string]$s) { "$ESC[38;2;${rgb}m$s$ESC[0m" }
function Pill([string]$fg, [string]$bg, [string]$s) { "$ESC[1m$ESC[38;2;${fg}m$ESC[48;2;${bg}m$s$ESC[0m" }

# ---- glyphs (Nerd Font) ----
$G_TMUX = [char]0xEBC8   # cod-terminal_tmux
$G_WIN  = [char]0xF2D0   # fa-window_maximize
$G_PANE = [char]0xF0DB   # fa-columns
$G_DOT  = [char]0x25CF   # ●
$A_RIGHT = [char]0x2192  # →
$A_DOWN  = [char]0x2193  # ↓

$PsmuxExe = (Get-Command psmux -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $PsmuxExe) { $PsmuxExe = 'psmux' }
# NB: call the resolved .exe, not the name — a function named Psmux would otherwise
# shadow the `psmux` command and recurse infinitely.
function Psmux { & $PsmuxExe @args 2>$null }

# ---- enumerate windows + panes into a numbered target list ----
# (list-* don't require an attached client; display-message -p would block when
#  run outside a real popup, so the start dir is derived from the active pane.)
$sep = '::;::'
$winLines  = @(Psmux list-windows -F "#{window_index}$sep#{window_id}$sep#{window_name}$sep#{window_active}")
$paneLines = @(Psmux list-panes -s -F "#{window_index}$sep#{pane_index}$sep#{pane_id}$sep#{pane_current_command}$sep#{pane_active}$sep#{pane_current_path}")

$cwd = $null
$panesByWin = @{}
foreach ($pl in $paneLines) {
    if (-not $pl) { continue }
    $f = $pl -split [regex]::Escape($sep)
    $wi = $f[0]
    $active = ($f[4] -eq '1')
    if ($active -and $f[5]) { $cwd = $f[5] }
    if (-not $panesByWin.ContainsKey($wi)) { $panesByWin[$wi] = New-Object System.Collections.Generic.List[object] }
    $panesByWin[$wi].Add([pscustomobject]@{ Win=$f[0]; Pane=$f[1]; Id=$f[2]; Cmd=$f[3]; Active=$active })
}
if (-not $cwd) { $cwd = $HOME }

$targets = New-Object System.Collections.Generic.List[object]
$n = 0

$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine('')
[void]$out.AppendLine('  ' + (Pill $C.darkfg $C.green " $G_TMUX psmux ") + ' ' + (FG $C.dim 'tabs, panes & actions'))
[void]$out.AppendLine('')

foreach ($wl in $winLines) {
    if (-not $wl) { continue }
    $wf = $wl -split [regex]::Escape($sep)
    $wIdx = $wf[0]; $wId = $wf[1]; $wName = $wf[2]; $wActive = ($wf[3] -eq '1')
    $n++
    $targets.Add([pscustomobject]@{ Num=$n; Kind='window'; Win=$wIdx; Id=$wId })
    $mark = if ($wActive) { FG $C.green "$G_DOT" } else { FG $C.dim ' ' }
    $numTag = Pill $C.darkfg $C.purple " $n "
    $label  = FG $C.purple "$G_WIN $wIdx`:$wName"
    [void]$out.AppendLine("   $numTag $mark $label")

    if ($panesByWin.ContainsKey($wIdx)) {
        $ps = $panesByWin[$wIdx]
        if ($ps.Count -gt 1) {
            foreach ($pane in $ps) {
                $n++
                $targets.Add([pscustomobject]@{ Num=$n; Kind='pane'; Win=$wId; Id=$pane.Id })
                $pmark = if ($pane.Active) { FG $C.blue "$G_DOT" } else { FG $C.dim ' ' }
                $pnum  = Pill $C.darkfg $C.blue " $n "
                $plabel = FG $C.blue "$G_PANE $wIdx.$($pane.Pane) $($pane.Cmd)"
                [void]$out.AppendLine("       $pnum $pmark $plabel")
            }
        }
    }
}

[void]$out.AppendLine('')
[void]$out.AppendLine('   ' + (FG $C.dim '─── actions ───'))
$actLine1 = '   ' +
    (Pill $C.darkfg $C.green ' c ') + ' ' + (FG $C.green 'New tab') + '    ' +
    (Pill $C.darkfg $C.cyan ' r ') + ' ' + (FG $C.cyan "New pane $A_RIGHT") + '    ' +
    (Pill $C.darkfg $C.cyan ' v ') + ' ' + (FG $C.cyan "New pane $A_DOWN")
$actLine2 = '   ' +
    (Pill $C.darkfg $C.yellow ' z ') + ' ' + (FG $C.yellow 'Zoom') + '       ' +
    (Pill $C.darkfg $C.orange ' n ') + ' ' + (FG $C.orange 'Rename tab') + ' ' +
    (Pill $C.darkfg $C.pink ' x ') + ' ' + (FG $C.pink 'Close pane') + '  ' +
    (Pill $C.darkfg $C.dim ' q ') + ' ' + (FG $C.dim 'Cancel')
[void]$out.AppendLine($actLine1)
[void]$out.AppendLine($actLine2)
[void]$out.AppendLine('')

[Console]::Out.Write($out.ToString())
[Console]::Out.Write('   ' + (FG $C.green '> '))

# ---- read selection ----
if ($PSBoundParameters.ContainsKey('Choice')) {
    $sel = $Choice
} else {
    $sel = Read-Host
}
$sel = ($sel + '').Trim()

switch -Regex ($sel) {
    '^[0-9]+$' {
        $t = $targets | Where-Object { $_.Num -eq [int]$sel } | Select-Object -First 1
        if ($t) {
            if ($t.Kind -eq 'window') {
                Psmux select-window -t $t.Id | Out-Null
            } else {
                Psmux select-window -t $t.Win | Out-Null
                Psmux select-pane -t $t.Id | Out-Null
            }
        }
        break
    }
    '^[cC]$' { Psmux new-window -c $cwd | Out-Null; break }
    '^[rR]$' { Psmux split-window -h -c $cwd | Out-Null; break }
    '^[vV]$' { Psmux split-window -v -c $cwd | Out-Null; break }
    '^[zZ]$' { Psmux resize-pane -Z | Out-Null; break }
    '^[nN]$' { Psmux command-prompt -I '#W' 'rename-window -- %%' | Out-Null; break }
    '^[xX]$' { Psmux kill-pane | Out-Null; break }
    default  { break }  # q / empty / unknown = cancel
}
