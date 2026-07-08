
# Copilot session helpers.
#
# These thin wrappers expose the copilot-session plugin's PowerShell script for
# interactive use from the shell. The SAME script backs the copilot-session
# skill, so there is a single implementation/source of truth: the plugin script
# under plugins\copilot-session. See that plugin's SKILL.md for full docs.

$script:CopilotSessionScript = (Join-Path $PSScriptRoot "plugins\copilot-session\skills\copilot-session\scripts\Copilot-Session.ps1");

# Find, create, or fork Copilot CLI sessions. All arguments are forwarded
# verbatim to the plugin script, e.g.:
#   Copilot-Session -Action Find -Path .
#   Copilot-Session -Action Find -Repository owner/repo
#   Copilot-Session -Action Fork -Session a8579b9 -NewName experiment -Launch
function Copilot-Session {
  & $script:CopilotSessionScript @args;
}

# Convenience wrappers that preset -Action.
function Find-CopilotSession { Copilot-Session -Action Find @args; }
function New-CopilotSession  { Copilot-Session -Action New  @args; }
function Fork-CopilotSession { Copilot-Session -Action Fork @args; }

# Short alias for the most common operation (searching).
Set-Alias -Name cops -Value Find-CopilotSession;
