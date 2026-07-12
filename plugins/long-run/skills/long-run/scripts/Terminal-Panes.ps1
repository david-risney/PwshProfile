# ============================================================================
# GENERATED FILE -- DO NOT EDIT.
# Vendored copy of shared/Terminal-Panes.ps1.
# Edit the source, then run tools\Sync-SharedScripts.ps1 to regenerate.
# ============================================================================

<#
.SYNOPSIS
Shared terminal/tab/pane helpers used by the PwshProfile plugins.

.DESCRIPTION
This is the SOURCE OF TRUTH for the terminal multiplexer helpers. Each plugin
that needs them vendors its own copy under its scripts\ folder so the plugin
stays self-contained (there is no runtime dependency on the repo layout). Run
tools\Sync-SharedScripts.ps1 to copy this file into the plugin copies, and
tools\Sync-SharedScripts.ps1 -Check (used by CI/pre-commit) to verify the
copies are in sync.

Do NOT edit the vendored copies directly -- edit this file and re-sync.

Functions:
  Resolve-WtExe     Return the wt.exe for the Windows Terminal edition that is
                    actually hosting the current process (stable vs Preview),
                    so 'wt -w 0 ...' targets the right window.
  Open-CommandPane  Open a program in a split pane beside the current one using
                    whichever multiplexer we're inside (psmux/zellij/Windows
                    Terminal), running the program as directly as each host
                    allows.
#>

# The generic 'wt.exe' app-execution alias targets whichever edition registered
# it last (often stable Windows Terminal). When we're actually running under
# Windows Terminal Preview that makes '-w 0 new-tab/split-pane' open in the
# WRONG window (or a new one). Walk up the parent process chain to the hosting
# WindowsTerminal.exe, read its image path to determine the package family
# (…WindowsTerminalPreview_… vs …WindowsTerminal_…), and return that edition's
# per-package wt.exe under %LOCALAPPDATA%\Microsoft\WindowsApps\<pkgfamily>\.
# Fall back to plain 'wt.exe' when the edition can't be determined or its exe is
# missing.
function Resolve-WtExe {
    $pkgFamily = $null
    try {
        $id = $PID
        for ($i = 0; $i -lt 12 -and $id; $i++) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
            if (-not $p) { break }
            if ($p.Name -eq 'WindowsTerminal.exe') {
                if ($p.ExecutablePath -match 'Microsoft\.WindowsTerminalPreview_') {
                    $pkgFamily = 'Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe'
                } elseif ($p.ExecutablePath -match 'Microsoft\.WindowsTerminal_') {
                    $pkgFamily = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe'
                }
                break
            }
            if ($p.ParentProcessId -eq $id) { break }
            $id = $p.ParentProcessId
        }
    } catch { }
    if ($pkgFamily) {
        $editionExe = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$pkgFamily\wt.exe"
        if (Test-Path -LiteralPath $editionExe) { return $editionExe }
    }
    return 'wt.exe'
}

# Open `$Command $Arguments` in a split pane beside the current one, in the given
# working directory, using whichever pane manager we're inside: psmux (TMUX),
# zellij (ZELLIJ), or Windows Terminal (WT_SESSION). Returns the host that was
# used ('psmux'/'zellij'/'wt'), or $null when no pane manager is available so the
# caller can fall back to running in place.
#
# Notes:
#  * Only psmux can honor 'Left' precisely (-b puts the new pane before the
#    current one). zellij's new-pane only supports right|down, and Windows
#    Terminal opens the new pane adjacent to the focused one, so for those two
#    'Left' is approximated as a normal side-by-side (right) split.
#  * psmux runs pane commands through its default-shell (an interactive pwsh),
#    which loads the full profile (~10s) before our command shows up. Unless
#    -KeepProfile is passed we set the PWSH_PROFILE_MINIMAL session env var so
#    that shell takes its fast minimal path, then clear it immediately after the
#    split (the pane already captured it at creation, so other panes are
#    unaffected). Pass $Command as a full exe path so it still resolves even
#    though the minimal profile skips PATH setup.
function Open-CommandPane {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$Cwd,
        [ValidateSet('Left', 'Right')][string]$Side = 'Right',
        [switch]$KeepProfile
    )
    if (-not $Cwd -or -not (Test-Path -LiteralPath $Cwd)) { $Cwd = (Get-Location).Path }

    if ($env:TMUX) {
        $psmux = Get-Command psmux, pmux -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($psmux) {
            $fast = -not $KeepProfile
            if ($fast) { & $psmux.Source set-environment PWSH_PROFILE_MINIMAL 1 2>$null | Out-Null }
            $split = @('split-window', '-h', '-c', $Cwd)
            if ($Side -eq 'Left') { $split += '-b' }   # -b: place the new pane before (left of) the current one
            $split += @('--', $Command) + $Arguments
            & $psmux.Source @split | Out-Null
            if ($fast) { & $psmux.Source set-environment -u PWSH_PROFILE_MINIMAL 2>$null | Out-Null }
            return 'psmux'
        }
    }
    if ($env:ZELLIJ) {
        $zj = Get-Command zellij -ErrorAction SilentlyContinue
        if ($zj) {
            & $zj.Source action new-pane --direction right --cwd $Cwd -- $Command @Arguments | Out-Null
            return 'zellij'
        }
    }
    if ($env:WT_SESSION) {
        $wtExe = Resolve-WtExe
        $hasWt = ($wtExe -ne 'wt.exe') -or [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
        if ($hasWt) {
            # -V = vertical divider => the two panes sit side by side.
            $wtArgs = @('-w', '0', 'split-pane', '-V', '--startingDirectory', $Cwd, $Command) + $Arguments
            Start-Process -FilePath $wtExe -ArgumentList $wtArgs | Out-Null
            return 'wt'
        }
    }
    return $null
}
