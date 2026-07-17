# Windows Terminal settings helpers.
# These functions know about Windows Terminal's settings.json schema (profiles,
# well-known profile GUIDs, dynamic profile sources, etc.). They rely on the
# generic JSON helpers in helper-json.ps1 (e.g. Out-FileAtomic) for file I/O so
# that helper-json.ps1 stays free of any terminal-specific knowledge.

# The name of the Windows Terminal fragment folder we generate live multiplexer
# session profiles into. Windows Terminal sets every fragment profile's "source"
# to its containing folder name, so this doubles as the matchProfiles "source"
# used to group those profiles into a New Tab menu folder.
$script:TerminalSessionFragmentSource = 'PwshProfile';

# The psmux window/pane icon (vendored from the psmux project, https://github.com/psmux/psmux).
# Two references are needed because Windows Terminal resolves icons differently:
#  * Top-level launcher (a plain settings.json profile): a normal file path, so we
#    point at the vendored copy in this repo and let %USERPROFILE% expand.
#  * Fragment session profiles: as of WT 1.24 fragment icons resolve RELATIVE TO
#    the fragment file's own directory (arbitrary/absolute paths are not honored),
#    so we copy the icon next to sessions.json and reference it by bare filename.
$script:PsmuxIconFileName = 'psmux-icon.png';
$script:PsmuxRepoIconPath = "%USERPROFILE%\PwshProfile\psmux\$script:PsmuxIconFileName";
$script:PsmuxSourceIconPath = Join-Path (Split-Path -Parent $PSCommandPath) "psmux\$script:PsmuxIconFileName";

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

  # Ensure the multiplexer "launch a new session" profiles (zellij, psmux) are
  # present at the TOP level of the dropdown. Each is added only if a profile with
  # its GUID isn't already present, so an existing customized entry (e.g. the
  # zellij profile some machines already have) is left untouched. These launchers
  # are deliberately plain settings.json profiles (NOT fragment/PwshProfile-sourced)
  # so matchProfiles doesn't pull them into the "Sessions" submenu - only the
  # per-running-session *attach* profiles (from the fragment) belong there. psmux is
  # launched via pwsh so profile.ps1 sets PSMUX_CONFIG_FILE and puts psmux on PATH.
  $muxProfiles = @(
    [PSCustomObject]@{
      guid              = '{efe05561-2955-40ef-9091-452d741951ca}';
      name              = 'ZelliJ';
      commandline       = '%LocalAppData%\Zellij\zellij.exe --config-dir %USERPROFILE%\PwshProfile\zellij';
      icon              = '%LocalAppData%\Zellij\zellij.exe';
      startingDirectory = '%USERPROFILE%';
      hidden            = $false;
    },
    [PSCustomObject]@{
      guid              = '{84494564-58d8-5fcf-806a-52635599b388}';
      name              = 'psmux';
      commandline       = 'pwsh -NoExit -Command psmux';
      icon              = $script:PsmuxRepoIconPath;
      startingDirectory = '%USERPROFILE%';
      hidden            = $false;
    }
  );
  foreach ($mux in $muxProfiles) {
    $existing = $list | Where-Object { $_.guid -eq $mux.guid } | Select-Object -First 1;
    if (!$existing) {
      $list += $mux;
    } elseif ($mux.icon) {
      # Keep the launcher icon current without clobbering any other user tweaks.
      $existing | Add-Member -NotePropertyName icon -NotePropertyValue $mux.icon -Force;
    }
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

  # NOTE: pruning of stale/orphaned fragment session stubs (and the matching
  # state.json generatedProfiles bookkeeping) is handled centrally by
  # Remove-OrphanedTerminalFragmentProfiles, invoked from
  # Update-TerminalSessionProfileFragment, so it isn't duplicated here.
  $json.profiles.list = @($list);

  # Make the pwsh (PowerShell Core) profile the default profile.
  $json | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $pwshGuid -Force;

  # Ensure a "Sessions" folder in the New Tab dropdown that auto-groups the live
  # zellij / psmux session profiles emitted into our fragment (they all share the
  # fragment folder name as their "source"). allowEmpty:false hides the folder
  # when there are no sessions; remainingProfiles keeps everything else at the top
  # level. We only add our folder if it isn't already present, so a user's own
  # newTabMenu customization is preserved.
  $sessionsFolder = [PSCustomObject]@{
    type       = 'folder';
    name       = 'Sessions';
    icon       = "$([char]0xD83D)$([char]0xDDD4)";  # desktop-window emoji
    allowEmpty = $false;
    entries    = @(
      [PSCustomObject]@{ type = 'matchProfiles'; source = $script:TerminalSessionFragmentSource }
    );
  };
  $menu = @();
  if ($json.PSObject.Properties['newTabMenu'] -and $json.newTabMenu) {
    $menu = @($json.newTabMenu);
  } else {
    # Default menu: everything at top level, then our Sessions folder.
    $menu = @([PSCustomObject]@{ type = 'remainingProfiles' });
  }
  $hasSessionsFolder = $menu | Where-Object {
    $_.type -eq 'folder' -and $_.entries -and (@($_.entries) | Where-Object {
      $_.type -eq 'matchProfiles' -and $_.source -eq $script:TerminalSessionFragmentSource
    });
  };
  if (!$hasSessionsFolder) {
    $menu += $sessionsFolder;
    $json | Add-Member -NotePropertyName newTabMenu -NotePropertyValue @($menu) -Force;
  }

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

# ---------------------------------------------------------------------------
# Dynamic Windows Terminal profiles for Edge / Chromium enlistments.
#
# The Edge / Chromium dev-environment "<Type> Shell (<root>)" profiles are exposed
# through a Windows Terminal JSON fragment extension rather than by editing
# settings.json directly. Benefits: the user's settings.json is never mutated,
# enlistments that go away disappear automatically when the fragment is regenerated,
# and everything cleans up if PwshProfile is removed. This uses its OWN fragment
# folder / source, kept separate from the multiplexer-session fragment below, so the
# two never interfere. Only the generic helpers (Get-TerminalSettingsPath,
# Remove-OrphanedTerminalFragmentProfiles, Remove-TerminalGeneratedProfileGuids,
# defined further down) are shared.
# ---------------------------------------------------------------------------
$script:TerminalDevEnvFragmentSource = 'PwshProfileDevEnv';

# The single shared fragment file all Windows Terminal editions read (there is no
# Preview-specific fragments path; see Get-TerminalFragmentPath below).
function Get-TerminalDevEnvFragmentPath {
  ,@(Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\$script:TerminalDevEnvFragmentSource\devenv.json")
}

# Build a fragment profile object for one discovered enlistment. The GUID is derived
# deterministically from the well-known Edge / Chromium namespace GUID (helper-misc.ps1's
# $WellKnownGuids) and the src path, so each enlistment keeps a stable profile even
# when several coexist.
#
# NOTE: fragment profile names must NOT contain a colon - WT keys fragment profiles
# as "{source}:{name}", so a colon hides them (microsoft/terminal#9521). The enlistment
# root carries a drive-letter colon, so it is stripped from the display name.
# $IconFileName, when set, is a bare filename resolved relative to the fragment dir.
function New-DevEnvironmentFragmentProfile {
  param(
    [Parameter(Mandatory)][ValidateSet('Edge', 'Chromium')][string]$Type,
    [Parameter(Mandatory)][string]$Src,
    [Parameter(Mandatory)][string]$Root,
    [string]$IconFileName
  )

  $namespaceGuid = $WellKnownGuids[$Type];
  $guid = '{{{0}}}' -f (New-UuidV5 -Namespace $namespaceGuid -NameStringOrBytes $Src);

  $initScript = Join-Path $Root 'depot_tools\scripts\setup\initEdgeEnv.ps1';
  $commandline = "pwsh -Interactive -ExecutionPolicy RemoteSigned -NoLogo -NoExit $initScript $Root";
  if ($Type -eq 'Chromium') { $commandline += ' --Chromium'; }

  $prof = [PSCustomObject]@{
    guid              = $guid;
    name              = "$Type Shell ($($Root -replace ':', ''))";
    commandline       = $commandline;
    startingDirectory = $Src;
  };
  if ($IconFileName) {
    $prof | Add-Member -NotePropertyName icon -NotePropertyValue $IconFileName -Force;
  }
  return $prof;
}

# Remove the legacy directly-written dev-environment profiles (the previous mechanism
# edited settings.json in place) so the fragment fully owns them. These are identified
# by an initEdgeEnv commandline whose "source" is anything other than our dev-env
# fragment source (fragment-rendered stubs carry that source, so they're preserved).
function Remove-LegacyDevEnvironmentProfiles {
  $src = $script:TerminalDevEnvFragmentSource;
  foreach ($settingsPath in (Get-TerminalSettingsPath)) {
    try {
      $raw = Get-Content -LiteralPath $settingsPath -Raw;
      if ([string]::IsNullOrWhiteSpace($raw)) { continue; }
      $json = $raw | ConvertFrom-Json;
    } catch { continue; }
    if (!$json.profiles -or !$json.profiles.PSObject.Properties['list'] -or !$json.profiles.list) { continue; }

    $list = @($json.profiles.list);
    $kept = @($list | Where-Object {
      !($_.commandline -and $_.commandline -match 'initEdgeEnv' -and $_.source -ne $src);
    });
    if ($kept.Count -ne $list.Count) {
      Write-Verbose "Migrating $($list.Count - $kept.Count) legacy dev profile(s) out of $settingsPath.";
      $json.profiles.list = @($kept);
      Out-FileAtomic ($json | ConvertTo-Json -Depth 32) $settingsPath;
    }
  }
}

# Regenerate the Edge / Chromium dev-environment fragment: one profile per discovered
# enlistment. Rewriting the fragment fully replaces it, so profiles for enlistments
# that have gone away disappear automatically. By default the fragment is written to
# the single shared fragments folder (see Get-TerminalDevEnvFragmentPath).
function Update-TerminalDevEnvironmentProfileFragment {
  param(
    [string[]]$FragmentPath = @(Get-TerminalDevEnvFragmentPath),
    [object[]]$Enlistments,
    [string[]]$SearchPatterns
  )

  if ($null -eq $Enlistments) {
    $Enlistments = @(Find-DevEnvironmentEnlistment -SearchPatterns $SearchPatterns);
  }

  # Ensure each fragment directory exists BEFORE copying icons into it (WT 1.24+
  # resolves fragment profile icons relative to the fragment's own directory).
  $fragmentDirs = @(@($FragmentPath) | ForEach-Object { Split-Path -Parent $_ });
  foreach ($dir in $fragmentDirs) {
    if (!(Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null;
    }
  }

  # Copy each enlistment's per-type icon next to the fragment and reference it by
  # bare filename; fall back to no icon (WT default) when the .ico is missing.
  $profiles = @();
  foreach ($e in $Enlistments) {
    $iconSource = Join-Path $e.Root ("depot_tools\scripts\setup\Powershell{0}.ico" -f $e.Type);
    $iconName = $null;
    if (Test-Path -LiteralPath $iconSource) {
      $iconName = "Powershell$($e.Type).ico";
      foreach ($dir in $fragmentDirs) {
        Copy-Item -LiteralPath $iconSource -Destination (Join-Path $dir $iconName) -Force -ErrorAction SilentlyContinue;
      }
    }
    $profiles += New-DevEnvironmentFragmentProfile -Type $e.Type -Src $e.Src -Root $e.Root -IconFileName $iconName;
  }

  # Fragments must be a { "profiles": [...] } object; force an array even for 0/1.
  $fragment = [PSCustomObject]@{ profiles = [object[]]@($profiles) };
  $outJson = $fragment | ConvertTo-Json -Depth 32;

  # Migrate away any legacy directly-written profiles and reconcile stale fragment
  # stubs BEFORE writing the fragment, so Terminal live-reloads onto a clean slate.
  Remove-LegacyDevEnvironmentProfiles;
  Remove-OrphanedTerminalFragmentProfiles $script:TerminalDevEnvFragmentSource $profiles;

  foreach ($path in @($FragmentPath)) {
    Out-FileAtomic $outJson $path 'Utf8';
  }
}

# ---------------------------------------------------------------------------
# Dynamic Windows Terminal profiles for running multiplexer sessions.
#
# Windows Terminal supports "JSON fragment extensions": .json files dropped under
#   %LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\<app>\<file>.json
# are merged into the user's settings without modifying settings.json itself
# (https://learn.microsoft.com/windows/terminal/json-fragment-extensions). We use
# one such fragment to expose a Terminal profile per *running* zellij / psmux
# session, each of which attaches to that session. Regenerating the fragment
# fully replaces it, so profiles for ended sessions disappear automatically.
# ---------------------------------------------------------------------------

# Resolve the zellij executable, preferring PATH then the well-known install dir.
function Get-ZellijExePath {
  $cmd = (Get-Command zellij -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source;
  if ($cmd) { return $cmd; }
  $fallback = Join-Path $env:LOCALAPPDATA 'Zellij\zellij.exe';
  if (Test-Path -LiteralPath $fallback) { return $fallback; }
  return $null;
}

# Parse the output of `zellij list-sessions -n` into the names of sessions that
# are currently alive (i.e. not marked EXITED / dead).
function ConvertFrom-ZellijSessionList ($lines) {
  $names = @();
  foreach ($line in @($lines)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue; }
    if ($line -match 'EXITED') { continue; }          # dead / resurrectable
    # Each line looks like: "<name> [Created ...] (...)"; take the first token.
    $name = ($line.Trim() -split '\s+', 2)[0];
    if ($name) { $names += $name; }
  }
  return $names;
}

# Names of the currently-running zellij sessions.
function Get-ZellijSessionName {
  $zellij = Get-ZellijExePath;
  if (!$zellij) { return @(); }
  $lines = & $zellij list-sessions -n 2>$null;
  if ($LASTEXITCODE -ne 0) { return @(); }            # "No active zellij sessions found."
  return (ConvertFrom-ZellijSessionList $lines);
}

# Names of the currently-running psmux sessions.
function Get-PsmuxSessionName {
  $psmux = (Get-Command psmux -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source;
  if (!$psmux) { return @(); }
  $lines = & $psmux ls -F '#{session_name}' 2>$null;
  if ($LASTEXITCODE -ne 0) { return @(); }
  return @($lines | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() });
}

# Build the fragment profile objects for the given zellij / psmux session names.
function New-TerminalSessionProfile {
  param(
    [string[]]$ZellijSessions = @(),
    [string[]]$PsmuxSessions  = @()
  )

  $profiles = @();

  # NOTE: fragment profile names must NOT contain a colon. Windows Terminal keys
  # fragment profiles internally as "{source}:{name}", so a colon in the name
  # prevents the profile from appearing in the dropdown (microsoft/terminal#9521).
  # Use " - " as the separator instead.
  foreach ($name in @($ZellijSessions)) {
    $guid = '{{{0}}}' -f (New-UuidV5 -NameStringOrBytes "zellij-session:$name");
    $profiles += [PSCustomObject]@{
      name              = "ZelliJ - $name";
      guid              = $guid;
      commandline       = "%LocalAppData%\Zellij\zellij.exe --config-dir %USERPROFILE%\PwshProfile\zellij attach $name";
      icon              = '%LocalAppData%\Zellij\zellij.exe';
      startingDirectory = '%USERPROFILE%';
    };
  }

  foreach ($name in @($PsmuxSessions)) {
    $guid = '{{{0}}}' -f (New-UuidV5 -NameStringOrBytes "psmux-session:$name");
    $profiles += [PSCustomObject]@{
      name              = "psmux - $name";
      guid              = $guid;
      # Launch via pwsh so profile.ps1 sets PSMUX_CONFIG_FILE and puts psmux on
      # PATH; single-quote the target so names with spaces attach correctly.
      commandline       = "pwsh -NoExit -Command `"psmux attach -t '$name'`"";
      icon              = $script:PsmuxIconFileName;
      startingDirectory = '%USERPROFILE%';
    };
  }

  return $profiles;
}

# The Windows Terminal settings.json locations we manage (Store, Preview, and
# unpackaged/portable installs). Only the ones that currently exist are returned.
function Get-TerminalSettingsPath {
  @(
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
  ) | Where-Object { Test-Path -LiteralPath $_ }
}

# Remove orphaned fragment stubs from settings.json AND keep Windows Terminal's
# state.json "generatedProfiles" list in sync. Terminal auto-persists a stub for
# every fragment profile it renders and records its GUID in generatedProfiles. Its
# rule: a GUID present in generatedProfiles but absent from profiles.list is treated
# as "the user deleted this profile" and is suppressed forever. So if we drop a stub
# (ended session, or a renamed one whose stale stub would otherwise override the
# fragment name) we MUST also drop its GUID from generatedProfiles, otherwise the
# session can never reappear. $KeepProfiles is the set the fragment currently defines.
function Remove-OrphanedTerminalFragmentProfiles ($Source, $KeepProfiles) {
  $src = $Source;
  $keepKeys = @(@($KeepProfiles) | ForEach-Object { "$($_.guid)|$($_.name)" });
  foreach ($settingsPath in (Get-TerminalSettingsPath)) {
    try {
      $raw = Get-Content -LiteralPath $settingsPath -Raw;
      if ([string]::IsNullOrWhiteSpace($raw)) { continue; }
      $json = $raw | ConvertFrom-Json;
    } catch { continue; }
    if (!$json.profiles -or !$json.profiles.PSObject.Properties['list'] -or !$json.profiles.list) { continue; }

    $list = @($json.profiles.list);
    $kept = @($list | Where-Object { $_.source -ne $src -or ($keepKeys -contains "$($_.guid)|$($_.name)") });
    if ($kept.Count -ne $list.Count) {
      $json.profiles.list = @($kept);
      Out-FileAtomic ($json | ConvertTo-Json -Depth 32) $settingsPath;
    }

    # GUIDs that must be "forgotten" so Terminal will regenerate them: any live
    # fragment profile that doesn't have an exact guid+name stub backing it right
    # now (e.g. just renamed, or WT hasn't rendered it yet). Steady-state profiles
    # whose stub matches are left untouched so there's no churn.
    $keptSrcKeys = @($kept | Where-Object { $_.source -eq $src } | ForEach-Object { "$($_.guid)|$($_.name)" });
    $forget = @(@($KeepProfiles) |
      Where-Object { $keptSrcKeys -notcontains "$($_.guid)|$($_.name)" } |
      ForEach-Object { ($_.guid -replace '[{}]', '') });
    if ($forget.Count) {
      Remove-TerminalGeneratedProfileGuids (Split-Path -Parent $settingsPath) $forget;
    }
  }
}

# Remove the given profile GUIDs from the "generatedProfiles" array in the
# state.json that sits alongside a settings.json (same LocalState folder). GUIDs
# are matched case-insensitively with or without surrounding braces.
function Remove-TerminalGeneratedProfileGuids ($SettingsDir, $Guids) {
  $statePath = Join-Path $SettingsDir 'state.json';
  if (!(Test-Path -LiteralPath $statePath)) { return; }
  try {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json;
  } catch { return; }
  if (!$state.PSObject.Properties['generatedProfiles'] -or !$state.generatedProfiles) { return; }

  $bare = @(@($Guids) | ForEach-Object { ($_ -replace '[{}]', '').ToLowerInvariant() });
  $orig = @($state.generatedProfiles);
  $kept = @($orig | Where-Object { $bare -notcontains (($_ -replace '[{}]', '').ToLowerInvariant()) });
  if ($kept.Count -ne $orig.Count) {
    $state.generatedProfiles = @($kept);
    Out-FileAtomic ($state | ConvertTo-Json -Depth 32) $statePath;
  }
}

# The Windows Terminal JSON-fragment file location. Per the WT docs, ALL editions
# (stable, Preview, unpackaged) read fragments from the single shared folder
# "%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\{app}\" - there is no
# Preview-specific fragments path - so we write exactly one file here.
function Get-TerminalFragmentPath {
  ,@(Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\$script:TerminalSessionFragmentSource\sessions.json")
}

# Regenerate the Windows Terminal fragment that exposes a profile per running
# zellij / psmux session. Writing an empty profiles list clears any stale entries
# from a previous run. By default the fragment is written to every installed
# edition's fragment folder (see Get-TerminalFragmentPath).
function Update-TerminalSessionProfileFragment {
  param(
    [string[]]$FragmentPath = @(Get-TerminalFragmentPath),
    [string[]]$ZellijSessions,
    [string[]]$PsmuxSessions
  )

  if ($null -eq $ZellijSessions) { $ZellijSessions = @(Get-ZellijSessionName); }
  if ($null -eq $PsmuxSessions)  { $PsmuxSessions  = @(Get-PsmuxSessionName); }

  $profiles = @(New-TerminalSessionProfile -ZellijSessions $ZellijSessions -PsmuxSessions $PsmuxSessions);

  # Fragments must be a { "profiles": [...] } object; force an array even for 0/1.
  $fragment = [PSCustomObject]@{ profiles = [object[]]@($profiles) };
  $outJson = $fragment | ConvertTo-Json -Depth 32;

  # Ensure each fragment directory exists and holds the icon (WT 1.24+ resolves
  # fragment profile icons relative to the fragment's own directory).
  foreach ($path in @($FragmentPath)) {
    $fragmentDir = Split-Path -Parent $path;
    if (!(Test-Path -LiteralPath $fragmentDir)) {
      New-Item -ItemType Directory -Path $fragmentDir -Force | Out-Null;
    }
    if (Test-Path -LiteralPath $script:PsmuxSourceIconPath) {
      Copy-Item -LiteralPath $script:PsmuxSourceIconPath `
        -Destination (Join-Path $fragmentDir $script:PsmuxIconFileName) -Force -ErrorAction SilentlyContinue;
    }
  }

  # Reconcile settings.json stubs and state.json generatedProfiles BEFORE writing
  # the fragment, so that when Terminal live-reloads on the fragment write it sees
  # a clean slate and regenerates the (possibly renamed) session profiles instead
  # of treating them as user-deleted. Then write the fragment last as the trigger.
  Remove-OrphanedTerminalFragmentProfiles $script:TerminalSessionFragmentSource $profiles;

  foreach ($path in @($FragmentPath)) {
    Out-FileAtomic $outJson $path 'Utf8';
  }
}
