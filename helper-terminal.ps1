# Windows Terminal settings helpers.
# These functions know about Windows Terminal's settings.json schema (profiles,
# well-known profile GUIDs, dynamic profile sources, etc.). They rely on the
# generic JSON helpers in helper-json.ps1 (e.g. Out-FileAtomic) for file I/O so
# that helper-json.ps1 stays free of any terminal-specific knowledge.

# Ensure a Windows Terminal settings.json has the PowerShell Core (pwsh) profile
# present and enabled, and hides the profiles we don't want in the dropdown:
# Windows PowerShell (powershell.exe), Command Prompt (cmd.exe), Azure Cloud Shell,
# and any Visual Studio developer profiles. This is done with conditional list
# manipulation (rather than a static JSON merge) so we never clobber the user's
# existing profiles.list.
function Update-TerminalProfiles ($settingsPath) {
  if (!(Test-Path -LiteralPath $settingsPath)) { return; }

  $raw = Get-Content -LiteralPath $settingsPath -Raw;
  if ([string]::IsNullOrWhiteSpace($raw)) { return; }

  try {
    $json = $raw | ConvertFrom-Json;
  } catch {
    Write-Verbose "Update-TerminalProfiles: could not parse $settingsPath; skipping.";
    return;
  }
  if (!$json.profiles) { return; }

  # Ensure profiles.list exists as an array we can append to.
  if (!$json.profiles.PSObject.Properties['list'] -or !$json.profiles.list) {
    $json.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() -Force;
  }
  $list = @($json.profiles.list);

  # Well-known deterministic GUIDs / dynamic profile sources.
  $pwshGuid        = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'; # PowerShell Core (pwsh)
  $winPowerShellGuid = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'; # Windows PowerShell
  $cmdGuid         = '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}'; # Command Prompt

  # Add the pwsh profile if it isn't already present, patterned after the
  # dynamically generated PowerShell Core profile.
  $hasPwsh = $list | Where-Object {
    $_.source -eq 'Windows.Terminal.PowershellCore' -or $_.guid -eq $pwshGuid;
  };
  if (!$hasPwsh) {
    $list += [PSCustomObject]@{
      guid   = $pwshGuid;
      hidden = $false;
      name   = 'PowerShell';
      source = 'Windows.Terminal.PowershellCore';
    };
  }

  # Hide the profiles we don't want to see.
  foreach ($prof in $list) {
    $shouldHide = $false;
    if ($prof.source -eq 'Windows.Terminal.Azure') { $shouldHide = $true; }        # Azure Cloud Shell
    if ($prof.source -eq 'Windows.Terminal.VisualStudio') { $shouldHide = $true; } # VS dev prompts
    if ($prof.guid -eq $winPowerShellGuid) { $shouldHide = $true; }
    if ($prof.guid -eq $cmdGuid) { $shouldHide = $true; }
    if ($prof.commandline -and $prof.commandline -match 'WindowsPowerShell\\v1\.0\\powershell\.exe') { $shouldHide = $true; }
    if ($prof.commandline -and $prof.commandline -match '\\cmd\.exe') { $shouldHide = $true; }

    if ($shouldHide) {
      $prof | Add-Member -NotePropertyName hidden -NotePropertyValue $true -Force;
    }
  }

  $json.profiles.list = @($list);

  # Make the pwsh (PowerShell Core) profile the default profile.
  $json | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $pwshGuid -Force;

  $outJson = $json | ConvertTo-Json -Depth 32;
  Out-FileAtomic $outJson $settingsPath;
}

# Git remote URL prefixes that identify a src folder as a Chromium or Edge
# development enlistment.
$script:DevEnvGitPrefixes = @{
  Chromium = 'https://chromium.googlesource.com/chromium/';
  Edge     = 'https://microsoft.visualstudio.com/DefaultCollection/Edge';
}

# Build the default enlistment search patterns: for every fixed (hard disk)
# drive, look for enlistments directly under the drive root (<drive>\*\src) and
# one level deeper under a "s" folder (<drive>\s\*\src).
function Get-DevEnvironmentSearchPattern {
  $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object {
    $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady;
  };
  foreach ($drive in $drives) {
    $root = $drive.Name.TrimEnd('\');  # e.g. "C:"
    "$root\*\src";
    "$root\s\*\src";
  }
}

# Discover Edge / Chromium development enlistments by looking for "src" folders
# under the given wildcard patterns (defaults to every fixed drive; see
# Get-DevEnvironmentSearchPattern). A candidate qualifies only if it is a git
# repository whose "origin" remote URL matches one of the known prefixes above.
# Returns objects with: Type ('Edge' | 'Chromium'), Src (the src folder) and
# Root (the enlistment root, i.e. the parent of src).
function Find-DevEnvironmentEnlistment {
  param(
    [string[]]$SearchPatterns
  )

  if (!$SearchPatterns) { $SearchPatterns = @(Get-DevEnvironmentSearchPattern); }

  $srcDirs = foreach ($pattern in $SearchPatterns) {
    # -Directory is a FileSystem dynamic parameter and fails to bind when the
    # drive doesn't exist, so skip patterns on missing drives and filter with
    # PSIsContainer instead.
    $qualifier = Split-Path -Qualifier $pattern -ErrorAction SilentlyContinue;
    if ($qualifier -and !(Test-Path -LiteralPath ($qualifier + '\'))) { continue; }
    Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
      Where-Object { $_.PSIsContainer -and $_.Name -eq 'src' }
  }

  $results = @();
  $seen = @{};
  foreach ($srcDir in $srcDirs) {
    $src = $srcDir.FullName;
    if ($seen.ContainsKey($src.ToLowerInvariant())) { continue; }
    $seen[$src.ToLowerInvariant()] = $true;

    $originUrl = (& git -C $src remote get-url origin 2>$null);
    if ([string]::IsNullOrWhiteSpace($originUrl)) { continue; }

    $type = $null;
    foreach ($kvp in $script:DevEnvGitPrefixes.GetEnumerator()) {
      if ($originUrl.StartsWith($kvp.Value, [System.StringComparison]::OrdinalIgnoreCase)) {
        $type = $kvp.Key;
        break;
      }
    }
    if (!$type) { continue; }

    $results += [PSCustomObject]@{
      Type = $type;
      Src  = $src;
      Root = (Split-Path -Parent $src);
    };
  }

  return $results;
}

# Build the Windows Terminal profile object for a discovered enlistment, following
# the schema documented on the wiki. The profile GUID is derived deterministically
# from the well-known Edge / Chromium namespace GUID (see helper-misc.ps1's
# $WellKnownGuids) and the src folder path, so each distinct enlistment gets its
# own stable profile even when several Edge or Chromium enlistments coexist.
function New-DevEnvironmentTerminalProfile {
  param(
    [Parameter(Mandatory)][ValidateSet('Edge', 'Chromium')][string]$Type,
    [Parameter(Mandatory)][string]$Src,
    [Parameter(Mandatory)][string]$Root
  )

  $namespaceGuid = $WellKnownGuids[$Type];
  $guid = '{{{0}}}' -f (New-UuidV5 -Namespace $namespaceGuid -NameStringOrBytes $Src);

  $initScript = Join-Path $Root 'depot_tools\scripts\setup\initEdgeEnv.ps1';
  $commandline = "pwsh -Interactive -ExecutionPolicy RemoteSigned -NoLogo -NoExit $initScript $Root";
  if ($Type -eq 'Chromium') { $commandline += ' --Chromium'; }

  $icon = Join-Path $Root ("depot_tools\scripts\setup\Powershell{0}.ico" -f $Type);

  return [PSCustomObject]@{
    guid             = $guid;
    commandline      = $commandline;
    startingDirectory = $Src;
    icon             = $icon;
    name             = "$Type Shell ($Root)";
  };
}

# Given a Windows Terminal profile commandline that invokes initEdgeEnv.ps1,
# return the enlistment's src folder path (the argument after the script, with
# "src" appended), or $null if it can't be determined.
function Get-InitEdgeEnvSrcPath ($commandline) {
  if ([string]::IsNullOrWhiteSpace($commandline)) { return $null; }
  # Capture the token following initEdgeEnv.ps1 (quoted or unquoted).
  if ($commandline -match 'initEdgeEnv\.ps1\s+(?:"([^"]+)"|(\S+))') {
    $root = if ($matches[1]) { $matches[1] } else { $matches[2] };
    return [System.IO.Path]::Combine($root, 'src');
  }
  return $null;
}

# Update a Windows Terminal settings.json with Edge / Chromium dev-environment
# profiles:
#   * Removes any existing initEdgeEnv-based profile whose src folder no longer
#     exists (stale enlistments).
#   * Adds or refreshes a profile for every enlistment discovered under
#     $SearchPatterns, keyed by the deterministic per-enlistment GUID.
# Uses conditional list manipulation so unrelated profiles are never touched.
function Update-TerminalDevEnvironmentProfiles {
  param(
    [string]$settingsPath,
    [string[]]$SearchPatterns
  )

  if (!(Test-Path -LiteralPath $settingsPath)) { return; }

  $raw = Get-Content -LiteralPath $settingsPath -Raw;
  if ([string]::IsNullOrWhiteSpace($raw)) { return; }

  try {
    $json = $raw | ConvertFrom-Json;
  } catch {
    Write-Verbose "Update-TerminalDevEnvironmentProfiles: could not parse $settingsPath; skipping.";
    return;
  }
  if (!$json.profiles) { return; }

  if (!$json.profiles.PSObject.Properties['list'] -or !$json.profiles.list) {
    $json.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() -Force;
  }
  $list = @($json.profiles.list);
  $changed = $false;

  # 1. Drop stale initEdgeEnv profiles whose src folder no longer exists.
  $kept = @();
  foreach ($prof in $list) {
    if ($prof.commandline -and $prof.commandline -match 'initEdgeEnv') {
      $src = Get-InitEdgeEnvSrcPath $prof.commandline;
      if ($src -and !(Test-Path -LiteralPath $src)) {
        Write-Verbose "Removing stale dev profile '$($prof.name)' (missing $src).";
        $changed = $true;
        continue;
      }
    }
    $kept += $prof;
  }
  $list = @($kept);

  # 2. Add or refresh a profile for each discovered enlistment.
  $enlistments = Find-DevEnvironmentEnlistment -SearchPatterns $SearchPatterns;
  foreach ($enlistment in $enlistments) {
    $desired = New-DevEnvironmentTerminalProfile -Type $enlistment.Type -Src $enlistment.Src -Root $enlistment.Root;

    $existing = $list | Where-Object { $_.guid -eq $desired.guid } | Select-Object -First 1;
    if ($existing) {
      foreach ($p in $desired.PSObject.Properties) {
        if (($existing.PSObject.Properties[$p.Name].Value) -ne $p.Value) {
          $existing | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force;
          $changed = $true;
        }
      }
    } else {
      Write-Verbose "Adding dev profile '$($desired.name)'.";
      $list += $desired;
      $changed = $true;
    }
  }

  if (!$changed) { return; }

  $json.profiles.list = @($list);
  $outJson = $json | ConvertTo-Json -Depth 32;
  Out-FileAtomic $outJson $settingsPath;
}
