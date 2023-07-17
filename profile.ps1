[CmdletBinding()]
param(
  [ValidateSet("On", "Off", "Async")] $Update = "Async",
  [ValidateSet("On", "Off", "Auto")] $WinFetch = "Auto");

$sw = [Diagnostics.Stopwatch]::StartNew()
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$global:progressIdx = 0;
# Find via (findstr /c "^IncrementProgress" .\profile.ps1).Count
$global:maxProgress = 15; # The count of IncrementProgress calls in this file.

if ($Update -eq "On") {
  $global:maxProgress += 3;
}

# Store an environment variable for the path to this folder
$env:PwshProfilePath = $PSScriptRoot;

function IncrementProgress {
  param($Name);
  ++$global:progressIdx;
  Write-Verbose ("Loading profile $Name " + " (" + $swTotal.Elapsed.ToString() + ", " + $sw.Elapsed.ToString() + ")");
  $sw.Restart();

  if ($global:progressIdx -eq $global:maxProgress) {
    Write-Progress -Activity "Loading Profile" -Complete;
  } else {
    $percentComplete = (($global:progressIdx) / ($global:maxProgress) * 100);
    if ($percentComplete -gt 100) {
      Write-Verbose ("You need to update maxProgress to reflect the actual count of IncrementProgress calls in this file.");
      $percentComplete = 100;
    }
    Write-Progress -Activity "Loading Profile" -Status $Name -PercentComplete $percentComplete;
  }
}

IncrementProgress "Starting";

if ($Update -eq "On") {
  Write-Verbose "Updating gsudo";
  winget install gerardog.gsudo;
  if (!(Get-Command gsudo -ErrorAction Ignore)) {
    $env:PATH += ";C:\Program Files\gsudo\Current\";
  }
  gsudo config CacheMode Auto
}

# Update PATHs to include all the bin-like folders in your user folder
$env:PATH = ($env:PATH.split(";") + @(Get-ChildItem ~\*bin) + @(Get-ChildItem ~\*bin\* -Directory) + @(Get-ChildItem ~\*bin\*bin -Directory)) -join ";";

# Asynchronously update compdb for ninja builds in VS
# if (Test-Path out\debug_x64) {
#     [void](Start-Job -ScriptBlock {
#         ninja -C out\debug_x64 -t compdb cxx > out\debug_x64\compile_commands.json ;
#         Show-Toast "Completed compdb update"
#     });
# }

# Avoid some python errors moving between old and new verions
$env:PYTHONIOENCODING = "UTF-8";

IncrementProgress "Setup PSRepository"
# This is all slow and so only do it when Update is set.
if ($Update -eq "On") {
  Write-Verbose "Set-PSRepository";
  if ((Get-PSRepository PSGallery).InstallationPolicy -ne "Trusted") {
    Set-PSRepository PSGallery -InstallationPolicy Trusted;
  }
}

# Update this profile script and associated files asynchronously
if ($Update -eq "On") {
  IncrementProgress "Update profile script"
  Write-Verbose "Update profile script";

  Push-Location ~\PwshProfile;
  # Use ff-only to hopefully avoid cases where merge is required
  git pull --ff-only

  $userProfilePath = (Join-Path $PSScriptRoot "profile.ps1");

  if (!(Get-Content $profile | Where-Object { $_.Contains($userProfilePath); })) {
      "`n. `"$userProfilePath`"" >> $profile;
  }
}

if ($Update -eq "On") {
  IncrementProgress "Update PowerShellGet";
  Write-Verbose "Update PowerShellGet";
  Install-Module -Name PowerShellGet -Force -Repository PSGallery -AllowPrerelease -Scope CurrentUser;
}

IncrementProgress "PSReadLine";
# PSReadLine gives improved input, tabbing, suggestions and such for
# PowerShell input
if ($Update -eq "On") {
  Write-Verbose "Update PSReadLine";
  gsudo { Install-Module PSReadLine -AllowPrerelease -Force; };
} else {
  Import-Module PSReadLine; # https://github.com/PowerShell/PSReadLine
}
Set-PSReadLineOption -PredictionSource History;
Set-PSReadLineOption -PredictionViewStyle ListView;
Set-PSReadLineOption -EditMode Windows;
 # Tab completion gets a menu. Must do before importing cd-extras
Set-PSReadLineKeyHandler Tab MenuComplete;

IncrementProgress "Terminal-Icons";
# Terminal-Icons adds "icons" and coloring to default dir output
# in PowerShell.
if ($Update -eq "On") {
  Write-Verbose "Update Terminal-Icons";
  Install-Module -Name Terminal-Icons -Repository PSGallery;
}
Import-Module Terminal-Icons; # https://www.hanselman.com/blog/take-your-windows-terminal-and-powershell-to-the-next-level-with-terminal-icons

IncrementProgress "cd-extras";
# cd-extras adds different functions for quickly moving between
# directories in your cd history, or directories with shortened
# names, and others.
if ($Update -eq "On") {
  Write-Verbose "Update cd-extras";
  Install-Module cd-extras
}
Import-Module cd-extras; # https://github.com/nickcox/cd-extras
setocd ColorCompletion; # Adds color to tab completion

Set-Alias back cd-;
Set-Alias fwd cd+;

# Get root folder of current source repository
function Get-LocationRoot {
    $root = $env:SDXROOT;
    if (!$root) {
        $root = (Get-Location).Path;
        while ($root) {
            if (Test-Path (Join-Path $root ".git\HEAD")) {
                break;
            } else {
                $root = Split-Path $root;
            }
        }
    }
    $root;
}

# Go to root folder of current source repository
function Set-LocationRoot {
    $root = (Get-LocationRoot);
    if ((Get-Location).Path -eq $root) {
        Set-Location ..
        $root = (Get-LocationRoot);
    }
    Set-Location $root;
}

Set-Alias \ Set-LocationRoot

IncrementProgress "BurntToast";
# BurntToast provides PowerShell commands to show OS toast
# notifications
if ($Update -eq "On") {
  Write-Verbose "Updating BurntToast";
  Install-Module -Name BurntToast
}
Import-Module BurntToast; # https://github.com/Windos/BurntToast

IncrementProgress "oh-my-posh";
# oh-my-posh lets you setup a pretty command prompt
# UpdateOrInstallWinget -ModuleName oh-my-posh -PackageName JanDeDobbeleer.OhMyPosh; # https://ohmyposh.dev/docs/pwsh/
if ($Update -eq "On") {
  Write-Verbose "Updating OhMyPosh";
  winget install JanDeDobbeleer.OhMyPosh -s winget
}
$ohmyposhConfigPath = (Join-Path $PSScriptRoot "oh-my-posh.json");
oh-my-posh init pwsh --config $ohmyposhConfigPath | Invoke-Expression;

# IncrementProgress "Posh-Git";
# Why are't I using posh git? Posh-Git does two things: 
# (1) a pretty prompt 
# I don't need the pretty prompt because I have oh-my-posh which does that and more.
# (2) tab completion. 
# I don't want tab completion because in big projects git is slow and then tab completion is very slow and blocks the prompt.
# With PSReadLine's menu completion, I can get some of the same functionality via history completion without the blocking.
# Accordingly, this is disabled
# UpdateOrInstallModule Posh-Git; # https://github.com/dahlbyk/posh-git

IncrementProgress "Nerd font check";
# Nerd fonts provide extra symbols useful for making a pretty prompt.
# General purpose icons like the branching icon, or company specific logos
# like the Windows logo, or GitHub logo, and ASCII art sort of icons.
# This is used by oh-my-posh and by Terminal-Icons
# https://ohmyposh.dev/docs/installation/fonts
if ($Update -eq "On") {
  # This maybe doesn't work when first installing gsudo.
  Write-Verbose "Updating font";
  gsudo { oh-my-posh font install CascadiaCode; };
} else {
  if (!(Get-ChildItem C:\windows\fonts\CaskaydiaCoveNerdFont*)) {
    Write-Error "Cascadia nerd font not found. Run the following from admin`n`toh-my-posh font install CascadiaCode;"
  }
}

# Function to get the URI of the current git repo set
# to the specificed path.
function Get-GitUri {
  param($Path);

  $Path = (Get-Item $Path).FullName.Replace("\", "/");

  $repoUri = (git config remote.origin.url);
  if ($repoUri) {
    if ($repoUri.Contains("github")) {
      $gitRootPath = (git rev-parse --show-toplevel).ToLower();
      $repoUri = $repoUri.Replace(".git", "");

      $currentPathInGit = $Path.Substring($gitRootPath.Length);

      $currentBranch = (git rev-parse --abbrev-ref HEAD);
      $uriEncodedCurrentBranch = [System.Web.HttpUtility]::UrlEncode($currentBranch);

      $repoUri = $repoUri + `
        "/tree/" + $uriEncodedCurrentBranch + `
        "/" + $currentPathInGit;
    } elseif ($repoUri.Contains("azure")) {
      $gitRootPath = (git rev-parse --show-toplevel).ToLower();
      $currentPathInGit = $Path.ToLower().Replace($gitRootPath, "");
      $uriEncodedCurrentPathInGit = [System.Web.HttpUtility]::UrlEncode($currentPathInGit);

      $currentBranch = (git rev-parse --abbrev-ref HEAD);
      $uriEncodedCurrentBranch = [System.Web.HttpUtility]::UrlEncode($currentBranch);

      $repoUri = $repoUri + `
        "?path=" + $uriEncodedCurrentPathInGit + `
        "&version=GB" + $uriEncodedCurrentBranch + `
        "&_a=contents";
    }

  }
 
  $repoUri;
}

IncrementProgress "Prompt shim";
# Shim the oh-my-posh prompt function to:
#  * add git info to oh-my-posh
#  * show toasts for long running commands
#  * add scrollbar mark support
Copy-Item Function:prompt Function:poshPrompt;
function prompt {
    $previousSuccess = $?;
    $previousLastExitCode = $global:LASTEXITCODE;
    $lastCommandSucceeded = !$previousLastExitCode -or $previousSuccess;

    try {
      $currentPath = ((Get-Location).Path);
      if ($env:OhMyPoshCustomBranchUriCachePath -ne $currentPath) {
        $env:OhMyPoshCustomBranchUri = Get-GitUri $currentPath;
        $env:OhMyPoshCustomBranchUriCachePath = $currentPath;
      }
    } catch {
      Write-Host ("Custom POSH env var prompt Error: " + $_);
    }

    # Scrollbar marks
    # https://learn.microsoft.com/en-us/windows/terminal/tutorials/shell-integration
    # Scrollbar mark - note start of prompt
    Write-Host "`e]133;A$([char]07)" -NoNewline;

    if (!$lastCommandSucceeded) {
        cmd /c "exit $previousLastExitCode";
    }

    try {
      poshPrompt;
    } catch {
      Write-Host ("POSH Prompt Error: " + $_);
    }

    # Scrollbar mark - note end of prompt
    Write-Host "`e]133;B$([char]07)" -NoNewLine;

    try {
      $lastCommandTookALongTime = $false;
      $lastCommandTime = 0;

      $h = (Get-History);
      if ($h.length -gt 0) {
          $lh = $h[$h.length - 1];
          $lastCommandTime = $lh.EndExecutionTime - $lh.StartExecutionTime;
          $lastCommandTookALongTime = $lastCommandTime.TotalSeconds -gt 10;
          if ($lh.ExecutionStatus -eq "Completed" -and $lastCommandTookALongTime) {
              $status = "Success: ";
              if (!$lastCommandSucceeded) {
                $status = "Failed: ";
              }
              New-BurntToastNotification -Text $status,($lh.CommandLine);
          }

          # Scrollbar mark - end of command including exit code
          if ($lastCommandSucceeded) {
            Write-Host "`e]133;D`a" -NoNewline;
          } else {
            Write-Host "`e]133;D;$gle`a" -NoNewline;
          }
      }

    } catch {
      Write-Host ("CDHistory Prompt Error: " + $_);
    }
    $global:LASTEXITCODE = 0;
}

IncrementProgress "Clickable paths";
# This function takes a URI and text, and returns
# the text formatted with ANSI escape sequence to make
# a link from that.
function Format-TerminalClickableString {
  param(
    $Uri,
    $DisplayText);

  $clickableFormatString = "`e]8;;{0}`e\{1}`e]8;;`e\"
  $formattedString = ($clickableFormatString -F ($Uri,$DisplayText));
  $formattedString;
}

# Make the result of dir into clickable links.
# This is used by ./TerminalClickable.format.ps1xml
function Format-TerminalClickableFileInfo {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
  [OutputType([string])]
  [CmdletBinding()]
  param(
      [Parameter(Mandatory, ValueFromPipeline)]
      [IO.FileSystemInfo]$FileInfo
  )

  process {
    if (Test-Path function:Format-TerminalIcons) {
      $displayText = Format-TerminalIcons $FileInfo;
    } else {
      $displayText = $FileInfo.Name;
    }
    Format-TerminalClickableString $FileInfo.FullName $displayText;
  }
}

# Run after Terminal-Icons to have both terminal-icons and clickable
# paths.
$terminableClickableFormatPath = (Join-Path $PSScriptRoot "TerminalClickable.format.ps1xml");
Update-FormatData -PrependPath $terminableClickableFormatPath;

IncrementProgress "Define helpful functions";

# Keep checking on the VPN connection and get it to reconnect if it
# disconnects.
function Connect-Vpn {
  function GetVpnStatus {
      $vpns = Get-VpnConnection;
      $date = (date);
      $vpns | ForEach-Object {
          New-Object -TypeName PSObject -Property @{'Date'=$date; 'Name'=$_.Name; 'ConnectionStatus'=$_.ConnectionStatus};
      }
  }

  function EnsureVpnConnection {
      $script:changed = $false;
      $vpns = GetVpnStatus;
      Write-Host ($vpns);
      $vpns | ForEach-Object {
          if ($_.ConnectionStatus -eq "Disconnected") {
              rasdial $_.Name;
              $script:changed = $true;
              Start-Sleep -Seconds 5;
          }
      }

      $script:changed;
  }


  while ($true) {
      $script:changed = (EnsureVpnConnection);
      if ($script:changed) {
          Write-Host (GetVpnStatus);
      }

      Start-Sleep -Seconds (60 * 0.5);
  }
}

function Open-WebView2Docs {
  <#
  .SYNOPSIS
  # WebView2-Docs.ps1 takes a WebView2 API name, and an optional parameter to say which language
  # to use (WinRT, .NET, Win32), and opens the corresponding WebView2 API documentation page in
  # the default browser.

  .EXAMPLE
  Launch-WebView2Docs AddHostObjectToScript -Language DotNet

  .EXAMPLE
  Launch-WebView2Docs -WhatIf AddHostObjectToScript
  #>
  param(
      [Parameter(Mandatory=$true)]
      [string] $Api,
      [Parameter(Mandatory=$false)][ValidateSet("Unknown", "WinRT", "DotNet", "Win32")]
      [string] $Language = "Unknown",
      # Equivalent to specifying -Language WinRT
      [switch] $WinRT,
      # Equivalent to specifying -Language Win32
      [switch] $Win32,
      # Equivalent to specifying -Language DotNet
      [switch] $DotNet,
      # Pass this switch to not actually open the browser, but instead list all
      # considered matches
      [switch] $WhatIf,
      # Consider all results in the WhatIf output not just filtered
      [switch] $All
  );

  if ($Language -eq "Unknown") {
      if ($WinRT) { $Language = "WinRT"; }
      elseif ($DotNet) { $Language = "DotNet"; }
      elseif ($Win32) { $Language = "Win32"; }
  }

  # We will query the MSDN search web API for its RSS result
  # String templates in .NET use {0}, {1}, etc. as placeholders for values
  $msdnSearchRssUriTemplate = "https://learn.microsoft.com/api/search/rss?search={0}&locale=en-us&facet=products&%24filter=scopes%2Fany%28t%3A+t+eq+%27WebView2%27%29";

  # First we fill in the template with a URI encoded string of the language, space, API name
  # For example, "WinRT CoreWebView2Environment" becomes "WinRT+CoreWebView2Environment"
  $encodedQuery = [System.Web.HttpUtility]::UrlEncode("$Language $Api");
  # Then we resolve the template to a URI using that query
  $msdnSearchRssUri = $msdnSearchRssUriTemplate -f $encodedQuery;

  # Next we perform a web request to that URI
  $msdnSearchRss = Invoke-WebRequest -Uri $msdnSearchRssUri;
  # And get the XML content of the HTTP response body out of that
  $msdnSearchRssXml = [xml]$msdnSearchRss.Content;

  function MatchStrength($result, $request) {
      $entryTitleLower = $result.ToLower();
      $apiLower = $request.ToLower();

      # Exact match wins
      if ($entryTitleLower -eq $apiLower) {
          0;
      } # Otherwise if it exists as a single word in the title thats great
      elseif ($entryTitleLower -like "* $apiLower *") {
          1;
      } # Or if it exists not as a single word but as a suffix
      elseif ($entryTitleLower -like "*$apiLower *") {
          2;
      } # Or a prefix
      elseif ($entryTitleLower -like "* $apiLower*") {
          3;
      } # Or just in there somewhere
      elseif ($entryTitleLower -contains $apiLower) {
          4;
      }
      else { # Otherwise...
          5;
      }
  }

  $languageToPathPart = @{
      "WinRT" = "/reference/winrt/";
      "DotNet" = "/dotnet/api/";
      "Win32" = "/reference/win32/";
  };

  # Convert the RSS items into PowerShell objects with a Title property, Uri property, Language property, and MatchStrength property
  # The MatchStrength property is a number that indicates how good of a match the result is where
  # 0 is the best and higher numbers are worse
  $results = $msdnSearchRssXml.rss.channel.item | ForEach-Object {
      $titleProperty = $_.title;
      $uriProperty = $_.link;
      $linkProperty = (Format-TerminalClickableString $_.link $_.title);
      $languageProperty = "Unknown";
      # Use languageToPathPart to determine which language the link is for
      foreach ($key in $languageToPathPart.Keys) {
          if ($uriProperty -like "*$($languageToPathPart[$key])*") {
              $languageProperty = $key;
              break;
          }
      }
      $matchStrengthProperty = MatchStrength $titleProperty $Api;

      New-Object PSObject -Property @{
          Title = $titleProperty;
          Uri = $uriProperty;
          Link = $linkProperty;
          Language = $languageProperty;
          MatchStrength = $matchStrengthProperty;
      };
  }

  $resultsFiltered = $results | Where-Object { $_.Language -eq $Language -or $Language -eq "Unknown" };

  # Now sort the results for better matches first
  # Titles that contain the API name are better matches than those that don't
  $resultsFilteredSorted = $resultsFiltered | Sort-Object -Property MatchStrength;
  if (!$All -and $resultsFilteredSorted.Count -gt 1) {
      $bestMatchStrength = $resultsFilteredSorted[0].MatchStrength;
      $resultsFilteredSorted = $resultsFilteredSorted | Where-Object { $_.MatchStrength -eq $bestMatchStrength };
  }

  if (!$WhatIf) {
      # Open default browser with the first result
      $firstResult = $resultsFilteredSorted[0];
      Start-Process $firstResult.Uri;
  } else {
      # List all results as PowerShell objects with title, uri, and
      # link which is the Title text but uses Unix escape sequence to
      # make it a link to Uri
      if ($Language -eq "Unknown") {
          $resultsFilteredSorted | Format-Table -Property Language,Link;
      } else {
          $resultsFilteredSorted | Format-Table -Property Link;
      }
  }
}

function GitRebaseOnto {
  <#
  .SYNOPSIS
  # Git-RebaseOnto.ps1 rebases the current branch onto an official branch.

  .EXAMPLE
  # Use git log -10 to find the branch source commit
  # Git-RebaseOnto.ps1 -BranchTarget main -BranchSource 38743dadac2951a19b397322280783cb4907224f -Verbose
  #>
  [CmdletBinding()]
  param(
      [Parameter(Mandatory=$true)] $BranchTarget,
      $BranchToRebase,
      [switch] $PullBranchToRebase,
      $BranchSource,
      [switch] $PullBranchSource,
      [switch] $WhatIf
      );

  if (!$BranchToRebase) {
      $BranchToRebase = git branch | Where-Object { $_.StartsWith("*") } | ForEach-Object { $_.substring(2) }
  }

  if (!$BranchSource) {
      $BranchSource = (git merge-base $BranchToRebase $BranchTarget);
  }

  Write-Verbose "BranchToRebase: $BranchToRebase";
  Write-Verbose "BranchSource: $BranchSource";
  Write-Verbose "BranchTarget: $BranchTarget";
  Write-Verbose "";

  if ($PullBranchSource) {
      Write-Verbose "Pull $BranchSource";
      if (!$WhatIf) {
          git checkout $BranchSource;
          git pull;
      }
  }

  Write-Verbose "Pull $BranchTarget";
  if (!$WhatIf) {
      git checkout $BranchTarget;
      git pull;
  }

  if ($PullBranchToRebase) {
      Write-Verbose "Pull $BranchToRebase";
      if (!$WhatIf) {
          git checkout $BranchToRebase;
          git pull;
      }
  }

  Write-Verbose "git rebase --onto $BranchTarget $BranchSource $BranchToRebase;";
  if (!$WhatIf) {
      git rebase --onto $BranchTarget $BranchSource $BranchToRebase;
  }

  Write-Verbose "Resulting status. You may need to finish a merge.";
  Write-Verbose 'git status (shows any changes under "Unmerged paths". Open the file and resolve the conflicts)'
  Write-Verbose 'git add <file that was resolved>'
  Write-Verbose 'git status (this will tell you all have been resolved)'
  Write-Verbose 'git rebase --continue (or git rebase --abort to get back to the state before the rebase was started)'
  Write-Warning 'If the branch has previously been pushed to the server, do *not* run git pull, instead run'
  Write-Warning '    git push --force'
}

function MergeJson ($jsons) {
    $settings = New-Object -TypeName Newtonsoft.Json.Linq.JsonMergeSettings
    $settings.MergeArrayHandling = [Newtonsoft.Json.Linq.MergeArrayHandling]::Replace;
    # Use newtonsoft to parse json into object
    $resultObject = $null;
    $jsons | ForEach-Object {
      $jsonObject = [Newtonsoft.Json.JsonConvert]::DeserializeObject($_);

      if (!$resultObject) {
        $resultObject = $jsonObject;
      } else {
        $resultObject.Merge($jsonObject, $settings);
      }
    } 

    $resultObject.ToString();
}

function MergeJsonFiles ($inJsonFilePaths, $outJsonFilePath, $encoding = "Utf8") {
  $inJson = ($inJsonFilePaths | ForEach-Object { 
    Get-Content $_ -Raw;
  });
  $outJson = MergeJson $inJson;
  $outJson | Out-File $outJsonFilePath -Encoding $encoding;
}

IncrementProgress "Applying Terminal settings";
# Merge terminal settings JSON into the various places Windows terminal stores its settings
$terminalSettingsPatchPath = (Join-Path $PSScriptRoot "terminal-settings.json");

@(
  "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
  "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
  "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
) | Where-Object {
  Test-Path $_;
} | ForEach-Object {
  $terminalSettingsPath = $_;
  MergeJsonFiles -inJsonFilePaths $terminalSettingsPath,$terminalSettingsPatchPath -outJsonFilePath (($terminalSettingsPath));
}

IncrementProgress "z";
# A port of the z bash script - z lets you quickly jump between
# directories in your cd history.
# https://github.com/badmotorfinger/z
# install-module z -AllowClobber
if ($Update -eq "On") {
  Write-Verbose "Updating z";
  install-module z -AllowClobber
}
Import-Module z;

IncrementProgress "bat";
# bat is a fancy version of cat / more / less with syntax highlighting
# If you get 'invalid charset name' make sure you don't have an old less.exe in your PATH
if (($Update -eq "On")) { # -or !(Get-Command bat -ErrorAction Ignore)) {
  Write-Verbose "Updating bat";
  winget install sharkdp.bat;
  # bat relies on less for paging
  Write-Verbose "Updating less";
  winget install jftuga.less;
}
# Use bat --list-themes to see all themes
# And then set the theme you want using:
$env:BAT_THEME = "OneHalfDark";
# Use some specific command line params with less:
# -X - don't clear the screen on exit
# -R - don't escape colors
# -F - quit if less than one screen
$env:BAT_PAGER = "less -RFX";

# I'm never going to remember to use bat because my fingers
# are too used to typing more. So just alias more to bat.
# Get-Content (gc) is the powershell version of cat that won't
# add line numbers and extra decorations and can handle 
# PowerShell specific paths like env: and function:
Set-Alias more bat;

# A version of which that says the path to the command but
# also handles PowerShell specific paths things like alias:
# and function:
function which {
  Get-Command -All $args[0] -ErrorAction Ignore | ForEach-Object {
    if ($_.Source.Length -gt 0) {
      $_.Source;
    } else {
      ("" + $_.CommandType) + ":" + $_.Name;
    }
  }
}

function touch {
  param($Path);
  if (Test-Path $Path) {
    (Get-Item $Path).LastWriteTime = Get-Date;
  } else {
    [void](New-Item $Path -ItemType File);
  }
}

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
  $env:NINJA_STATUS = "`e[1;37;44m[`e]8;;$gomaUri`e\%r running, %f/%t @ %c/s %o/s : %es`e]8;;`e\]`e[0m ";
}

if ($Update -eq "Async") {
  $lastAsyncUpdatePath = (Join-Path "~" "pwsh-profile-last-async-update.txt");
  $lastAsyncUpdate = $null;

  if (Test-Path $lastAsyncUpdatePath) {
    $lastAsyncUpdate = (Get-Item $lastAsyncUpdatePath).LastWriteTime;
  }

  if (!($lastAsyncUpdate) -or ((Get-Date) -gt $lastAsyncUpdate.AddMinutes(60))) {
    # Touch before starting update because the update may take a long time.
    touch $lastAsyncUpdatePath;

    $userProfilePath = (Join-Path $PSScriptRoot "profile.ps1");

    Write-Host "Starting async update...";
    [void](Start-Job -Name ProfileAsyncInstallOrUpdate -ScriptBlock {
      param($userProfilePath);
      .$userProfilePath -Update On -Verbose;
      $success = $LASTEXITCODE -eq 0 -and $?;
      New-BurntToastNotification -Text "Profile Update",$success;
    } -ArgumentList $userProfilePath);
  }
}

function Get-GitChangePaths {
  [CmdletBinding()]
  param(
    $SetPathMatch,
    [switch] $FullPaths,
    [switch] $OnlyGitStatusFiles,
    [switch] $RebuildCache,
    $BranchCommit);

  if (!$global:gitChangePathsCache -or $RebuildCache) {
    Write-Verbose "Rebuilding git change paths cache";
    $gitRoot = (git rev-parse --show-toplevel);
    Write-Verbose ("gitroot: " + $gitRoot);

    if (!$BranchCommit) {
      $BranchCommit = (git merge-base origin/main HEAD);
    }
    Write-Verbose ("Branch commit: " + $BranchCommit);

    $gitStatusFiles = git status -s | ForEach-Object {
      $path = $_.substring(3);
      if (Test-Path $path) {
        (Get-Item $path).FullName;
      }
    };
    Write-Verbose "Found $($gitStatusFiles.Count) git status files";

    if (!$OnlyGitStatusFiles) {
      $gitBranchFiles = git diff --name-only $BranchCommit | ForEach-Object {
        $path = (Join-Path $gitRoot $_);
        if (Test-Path $path) {
          (Get-Item $path).FullName;
        }
      };
      Write-Verbose "Found $($gitBranchFiles.Count) git branch files";
    }

    $gitFiles = @($gitStatusFiles) + @($gitBranchFiles);
    $global:gitChangePathsCache = $gitFiles;
  } else {
    Write-Verbose "Using cached git change paths";
  }

  $gitFiles = $global:gitChangePathsCache;

  if (!$FullPaths) {
    # Convert to containing folder paths
    $gitFiles = $gitFiles | ForEach-Object {
      (Split-Path $_ -Parent);
    };
  }

  $gitFiles = $gitFiles | Sort-Object -Unique;
  if ($null -ne $SetPathMatch) {
    # Filter to just matching paths
    $gitFiles = $gitFiles | Where-Object { $_ -match $SetPathMatch };
    Write-Verbose "Found $($gitFiles.Count) matching git change paths";

    if ($gitFiles.Count -gt 1) {
      # Reorder array to start with firstMatchIndex and then wrap around.
      # This way if we're currently on a file that matches the set path match we'll go to the next path
      # in the list if we're called the same way again.
      $firstMatchIndex = 0;
      $cwd = (Get-Location).Path;
      while ($firstMatchIndex -lt $gitFiles.Length -and $gitFiles[$firstMatchIndex].ToLower() -ne $cwd.ToLower()) {
        ++$firstMatchIndex;
      }
      # If we're on the last index or no match was found, no need to reorder
      if ($firstMatchIndex -lt $gitFiles.Length - 1) {
        $gitFiles = $gitFiles[($firstMatchIndex + 1)..($gitFiles.Length - 1)] + $gitFiles[0..$firstMatchIndex];
      }
    }

    if ($gitFiles.Count -gt 0) {
      Set-Location $gitFiles[0];
    }
  } else {
    $gitFiles;
  }
}

function gitcd {
  [CmdletBinding()]
  param($SetPathMatch = "");
  Get-GitChangePaths -SetPathMatch $SetPathMatch;
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
    $prefix = "$gitRoot\out";
    if ((Get-Location).Path.ToLower().StartsWith($prefix.ToLower())) {
      $OutPath = (Get-Location).Path.Substring($prefix.Length + 1).Split("\")[0];
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
    $gnRefs += ($BuildTargets);
  }

  if (!($WhatIf)) {
    "---START LOG note---" > $LogPath;
    autoninja -C $OutPath $gnRefs | Tee-Object -Append -FilePath $LogPath -Encoding Utf8;
    "---END LOG note---" >> $LogPath;
    "" >> $LogPath;
  } else {
    $gnRefs | ForEach-Object { Write-Output $_; };
  }
}

if ($Update -eq "On") {
  IncrementProgress "Update various apps";

  Write-Verbose "Update ripgrep";
  winget install BurntSushi.ripgrep.MSVC;
  Write-Verbose "Update powershell";
  winget install --id Microsoft.Powershell --source winget;
  Write-Verbose "Update git";
  winget install git --source winget;
  # The following installs could take a while and they aren't
  # requirements for anything else in this script
  # So run them in a different command prompt
  Write-Verbose "Update powertoys";
  winget install Microsoft.PowerToys;
  Write-Verbose "Update vscode";
  winget install Microsoft.VisualStudioCode;
  Write-Verbose "Update vs";
  winget install Microsoft.VisualStudio.2022.Enterprise;
}

IncrementProgress "Copying VSCode tasks.json";
Copy-Item (Join-Path $PSScriptRoot "tasks.json") $env:APPDATA\code\user\tasks.json;

IncrementProgress "Done";

# WinFetch basically just looks cool
# We run it last AFTER all the IncrememntProgress calls because the
# PowerShell progress indicator clears the WinFetch logo display
if ($WinFetch -eq "Auto") {
  if ((Get-Process -Id $PID).Parent.ProcessName -eq "WindowsTerminal") {
    $WinFetch = "On";
  } else {
    $WinFetch = "Off";
  }
}

if ($WinFetch -eq "On") {
  # Invoke-WebRequest "https://raw.githubusercontent.com/lptstr/winfetch/master/winfetch.ps1" -OutFile .\winfetch.ps1 -UseBasicParsing
  $winfetchPath = (Join-Path $PSScriptRoot "winfetch.ps1");
  $winfetchConfigPath = (Join-Path $PSScriptRoot "winfetch-config.ps1");
  $winfetchLogoPath = (Join-Path $PSScriptRoot "logo.png");
  .$winfetchPath -config $winfetchConfigPath -image $winfetchLogoPath;
}

# Ideas:
# * Fix terminal-icons
# * Change winfetch logo for my edge repos
# * Better icon for toast
# * Consider extracting grouped chunks out into modules
# * Check out https://github.com/dandavison/delta
