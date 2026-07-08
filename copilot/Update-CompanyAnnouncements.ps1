<#
.SYNOPSIS
  Populate the GitHub Copilot CLI user settings' companyAnnouncements with the
  contents of every gifs\*.one.ansi file (one entry per file).

.DESCRIPTION
  Each gifs\*.one.ansi file contains a single frame of ANSI art. This script
  reads them all and writes them as the companyAnnouncements array in the
  Copilot CLI user settings.json, preserving all other settings. profile.ps1
  invokes this whenever the number of announcements no longer matches the number
  of *.one.ansi files.
#>
[CmdletBinding()]
param(
  [string] $GifsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "gifs"),
  [string] $SettingsPath = (Join-Path $env:USERPROFILE ".copilot\settings.json")
)

$ErrorActionPreference = 'Stop';

# Reuse Out-FileAtomic for a safe, race-free write.
. (Join-Path (Split-Path -Parent $PSScriptRoot) "helper-json.ps1");

# Gather the first-frame ANSI art, one announcement per file (stable order).
$ansiFiles = @(Get-ChildItem -Path $GifsPath -Filter '*.one.ansi' -File | Sort-Object Name);
$announcements = [string[]]@($ansiFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) });

# Load existing settings so we only touch companyAnnouncements.
if (Test-Path -LiteralPath $SettingsPath) {
  $raw = Get-Content -LiteralPath $SettingsPath -Raw;
  if ([string]::IsNullOrWhiteSpace($raw)) {
    $settings = [PSCustomObject]@{};
  } else {
    $settings = $raw | ConvertFrom-Json;
  }
} else {
  $settings = [PSCustomObject]@{};
  $settingsDir = Split-Path -Parent $SettingsPath;
  if ($settingsDir -and !(Test-Path -LiteralPath $settingsDir)) {
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null;
  }
}

$settings | Add-Member -NotePropertyName companyAnnouncements -NotePropertyValue $announcements -Force;

$outJson = $settings | ConvertTo-Json -Depth 32;
Out-FileAtomic $outJson $SettingsPath;

Write-Verbose "Set $($announcements.Count) companyAnnouncements from $GifsPath into $SettingsPath.";
