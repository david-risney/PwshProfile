<#
.SYNOPSIS
  Regenerate the Windows Terminal JSON fragment that exposes a profile per
  running zellij / psmux session.

.DESCRIPTION
  Standalone entry point (loads only the helpers it needs, with -NoProfile) so it
  can be invoked cheaply from psmux hooks (set-hook -g session-created/-closed via
  run-shell) as well as from profile.ps1 at shell startup. See helper-terminal.ps1
  Update-TerminalSessionProfileFragment for details.
#>

$root = $PSScriptRoot;
. (Join-Path $root 'helper-misc.ps1');
. (Join-Path $root 'helper-json.ps1');
. (Join-Path $root 'helper-terminal.ps1');

# Invoked from psmux hooks, so it must stay silent and never fail the hook. If the
# settings/fragment files are momentarily locked (Terminal reloading, Defender,
# OneDrive), just skip - the next hook or shell startup reconciles.
try {
  Update-TerminalSessionProfileFragment;
} catch {
  Write-Verbose "Update-TerminalSessionFragment skipped: $($_.Exception.Message)";
}
