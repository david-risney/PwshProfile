[CmdletBinding()]
param();

# Asynchronously update compdb for ninja builds in VS
# if (Test-Path out\debug_x64) {
#     [void](Start-Job -ScriptBlock {
#         ninja -C out\debug_x64 -t compdb cxx > out\debug_x64\compile_commands.json ;
#         Show-Toast "Completed compdb update"
#     });
# }

# Fancy ninja status
if (Get-Command goma_ctl -ErrorAction Ignore) {
  # See https://chromium.googlesource.com/infra/goma/client/+/refs/heads/main/client/goma_ctl.py
  $gomaUri = @((goma_ctl status) | ForEach-Object { if ($_ -match "(http[^ ]+)") { $matches[1] } })[0];
  # The first ` e escape sequence changes to blue on white text
  # The second changes the text to be a link to the goma uri
  # The third closes the link
  # The fourth resets the color
  # See https://ninja-build.org/manual.html#:~:text=control%20its%20behavior%3A-,NINJA_STATUS,-%2C%20the%20progress%20status
  # for more info on the percent escape codes for NINJA_STATUS
  # Use `e]9;4... to show progress https://learn.microsoft.com/en-us/windows/terminal/tutorials/progress-bar-sequences
  $env:NINJA_STATUS = "`e[K`e[1;37;44m[`e]8;;$gomaUri`e\%f/%t`e]8;;`e\]`e[0m";
}

function Format-TerminalClickableString {
  param(
    $Uri,
    $DisplayText);

  $clickableFormatString = "`e]8;;{0}`e\{1}`e]8;;`e\"
  $formattedString = ($clickableFormatString -F ($Uri,$DisplayText));
  $formattedString;
}

function Build-AutoNinja {
  [CmdletBinding()]
  param(
    $BuildTargets,
    [ValidateSet("none", "immediate", "test", "retail")] $DiscoverBuildTargets = "none",
    [switch] $UseCachedDiscoveredBuildTargets,
    [Alias("C")] $OutPath,
    $LogPath,
    [switch] $WhatIf);

  if (!($BuildTargets)) {
    $DiscoverBuildTargets = "immediate";
  }

  $gitRoot = (git rev-parse --show-toplevel);
  Write-Verbose ("gitroot: " + $gitRoot);

  if (!$OutPath) {
    # Check if we're in an out path
    $prefix = "$gitRoot\out".Replace("/", "\");
    if ((Get-Location).Path.ToLower().StartsWith($prefix.ToLower())) {
      $OutPath = (Join-Path $prefix ((Get-Location).Path.Substring($prefix.Length + 1).Split("\")[0]));
    }
  }

  if (!$OutPath) {
    # find the most recently run folder under gitRoot\out
    $OutPath = (Get-ChildItem -Path "$gitRoot\out" -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName;
  }
  Write-Verbose ("Outpath: " + $OutPath);

  if (!$LogPath) {
    $LogPath = (Join-Path $OutPath "build.log");
  }
  Write-Verbose ("LogPath: " + $LogPath);

  $gnRefs = "";

  if (($DiscoverBuildTargets -ne "none") -and !($global:AutoNinjaCache -and $UseCachedDiscoveredBuildTargets)) {
    $gitStatusFiles = Get-GitChangePaths -FullPaths -RebuildCache;
    Write-Verbose ("git status files: " + $gitStatusFiles);

    if ($DiscoverBuildTargets -eq "immediate") {
      $gnRefs = (gn refs $OutPath $gitStatusFiles | ForEach-Object { $_.substring(2); });
    } elseif ($DiscoverBuildTargets -eq "test") {
      $gnRefs = gn refs $OutPath $gitStatusFiles --all --testonly=true --type=executable --as=output;
    } elseif ($DiscoverBuildTargets -eq "retail") {
      $gnRefs = gn refs $OutPath $gitStatusFiles --all --testonly=false --type=executable --as=output;
    }
    Write-Verbose ("gn refs: " + $gnRefs);

    $global:AutoNinjaCache = $gnRefs;
  }
  if ($DiscoverBuildTargets) {
    $gnRefs = $global:AutoNinjaCache;
  }
  if ($BuildTargets) {
    if ($gnRefs) {
      $gnRefs += " ";
    }
    $gnRefs += $BuildTargets;
  }

  if (!($WhatIf)) {
    $foundError = $false;

    Write-Verbose "Starting autoninja -C $OutPath $gnRefs";
    "" > $LogPath;
    "---START LOG note---" >> $LogPath;
    autoninja.bat -C $OutPath $gnRefs | Tee-Object -Append -FilePath $LogPath -Encoding Utf8 | ForEach-Object {
      $out = $_;
      if ($_ -match "([0-9]+)/([0-9]+)") {
        $percent = [int]$matches[1];
        $total = [int]$matches[2];
        $progress = [int]($percent * 100 / $total);
        $state = "1";
        if ($foundError) {
          $state = "2";
        }
        # https://learn.microsoft.com/en-us/windows/terminal/tutorials/progress-bar-sequences
        $out += "`e]9;4;$state;$progress`e\";
      }
      if ($_ -match ": error") {
        $out += "`e]133;D;1`e\";
        if ($out -match "^([^ ]+)(\([0-9]+)") {
          $path = Join-Path $OutPath $matches[1];
          $clickableString = (Format-TerminalClickableString -Uri $path -DisplayText $matches[1]);
          $out = $clickableString + $out.Substring($matches[1].Length);
        }
      }
      $out;
    };
    "---END LOG note---" >> $LogPath;
    "" >> $LogPath;
  } else {
    $gnRefs | ForEach-Object { Write-Output $_; };
  }

  # Clear progress
  Write-Host "`e]9;4;0;0`e\";
}
New-Alias -f autoninja Build-Autoninja;

# Todo
# * Merge vscode tasks and settings JSON
#    * C:\Users\davris\AppData\Roaming\Code\User\settings.json
#    * C:\Users\davris\AppData\Roaming\Code\User\tasks.json
# * Vscode terminal font settings 
#    `"terminal.integrated.fontFamily": "CaskaydiaCove Nerd Font Mono"`
# * Vscode terminal settings 
#    ```
#      "code (Pwsh)": {
#        "path": [
#          "pwsh.exe",
#          "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
#        ],
#        "icon": "source-control",
#        "args": [
#          "-NoLogo",
#          "-NoExit",
#          "-NoProfileLoadTime",
#          "-Command",
#          "${workspaceRoot}\\..\\depot_tools\\scripts\\setup\\initEdgeEnv.ps1 ${workspaceRoot}\\.. ; . ${home}\\PwshProfile\\ninja-profile.ps1"
#        ],
#        "overrideName": true
#      }
#    ```