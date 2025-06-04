<#
.Description
[Dave Risney's profile.ps1](https://github.com/david-risney/PwshProfile). Install, load, and configure command line tools
and such for PowerShell.
#>
[CmdletBinding()]
param(
  [ValidateSet("On", "Off", "Async")] $Update = "Async",
  [ValidateSet("On", "Off", "Auto")] $WinFetch = "Auto");

. (Join-Path $PSScriptRoot "helper-progress.ps1");

# Find via (findstr /c "^IncrementProgress" .\profile.ps1).Count
$global:maxProgress = 18; # The count of IncrementProgress calls in this file.

if ($Update -eq "On") {
  $global:maxProgress += 4;
}

# Store an environment variable for the path to this folder
$env:PwshProfilePath = $PSScriptRoot;

IncrementProgress "Starting";

Write-Verbose ("Update is " + $Update);

# gsudo lets you easily run commands as administrator from PowerShell
# https://github.com/gerardog/gsudo
if ($Update -eq "On") {
  Write-Verbose "Updating gsudo";
  winget install gerardog.gsudo;
  if (!(Get-Command gsudo -ErrorAction Ignore)) {
    $env:PATH += ";C:\Program Files\gsudo\Current\";
  }
  gsudo config CacheMode Auto
}

if ($Update -eq "On") {
  Write-Verbose "Updating TerminalPreview";
  winget install Microsoft.WindowsTerminal.Preview;
}

if ($Update -eq "On") {
  Write-Verbose "Updating SysInteranls";
  winget install Microsoft.Sysinternals;
}

if ($Update -eq "On") {
  Write-Verbose "Updating GH CLI";
  winget install GitHub.cli

  if (Get-Command gh -ErrorAction Ignore) {
    # If gh is already installed, then update it
    if (!(gh extension list | findstr copilot)) {
      gh auth login;
      gh extension install copilot;
    }
  }
}

# Update PATHs to include all the bin-like folders in your user folder
$env:PATH = ($env:PATH.split(";") + @(Get-ChildItem ~\*bin) + @(Get-ChildItem ~\*bin\* -Directory) + @(Get-ChildItem ~\*bin\*bin -Directory)) -join ";";

# Avoid some python errors moving between old and new verions
$env:PYTHONIOENCODING = "UTF-8";

# Some install and update requires setting up the PSRepository.
# But it is slow and so only do it when're actually updating.
if ($Update -eq "On") {
  IncrementProgress "Setup PSRepository"
  Write-Verbose "Set-PSRepository";
  if ((Get-PSRepository PSGallery).InstallationPolicy -ne "Trusted") {
    Set-PSRepository PSGallery -InstallationPolicy Trusted;
  }
}

IncrementProgress "Loading Git Helpers";
. (Join-Path $PSScriptRoot "helper-git.ps1");

IncrementProgress "Loading Misc Helpers";
. (Join-Path $PSScriptRoot "helper-misc.ps1");

IncrementProgress "Loading Json Helpers";
. (Join-Path $PSScriptRoot "helper-json.ps1");

IncrementProgress "Loading WebView2 Helpers";
. (Join-Path $PSScriptRoot "helper-webview2.ps1");

IncrementProgress "Loading Web Helpers";
. (Join-Path $PSScriptRoot "helper-web.ps1");

#region profile update
# Update this profile script and associated files asynchronously
# https://github.com/david-risney/PwshProfile
if ($Update -eq "On") {
  IncrementProgress "Update profile script"
  Write-Verbose "Update profile script";

  Push-Location ~\PwshProfile;
  # Use ff-only to hopefully avoid cases where merge is required
  git pull --ff-only

  $userProfilePath = (Join-Path $PSScriptRoot "profile.ps1").ToLower();

  if (!(Get-Content $profile | ForEach-Object { $_.ToLower(); } | Where-Object { $_.Contains($userProfilePath); })) {
      "`n. `"$userProfilePath`"" >> $profile;
  }
}
#endregion

#region update powershellget
# PowerShellGet is the module that lets you install other modules and is required
# for installing or updating some of the modules below.
# But it is slow and we only do it when we're actually updating.
# https://learn.microsoft.com/en-us/powershell/gallery/powershellget/overview
if ($Update -eq "On") {
  IncrementProgress "Update PowerShellGet";
  Write-Verbose "Update PowerShellGet";
  Install-Module -Name PowerShellGet -Force -Repository PSGallery -AllowPrerelease -Scope CurrentUser -SkipPublisherCheck;
  Import-Module PowerShellGet;
}
#endregion

#region PSReadLine
# [PSReadLine](https://github.com/david-risney/PwshProfile) gives improved and customized input, tabbing, suggestions and such for
# PowerShell input and command line editing.
IncrementProgress "PSReadLine";
if ($Update -eq "On") {
  Write-Verbose "Update PSReadLine";
  gsudo { Install-Module PSReadLine -AllowPrerelease -Force -SkipPublisherCheck; };
} else {
  Import-Module PSReadLine; # https://github.com/PowerShell/PSReadLine
}
Set-PSReadLineOption -PredictionSource History;
Set-PSReadLineOption -PredictionViewStyle ListView;
Set-PSReadLineOption -EditMode Windows;
 # Tab completion gets a menu. Must do before importing cd-extras
Set-PSReadLineKeyHandler Tab MenuComplete;
#endregion

#region terminal-icons
# [Terminal-Icons](https://github.com/david-risney/PwshProfile) adds "icons" and coloring to default dir output
# in PowerShell. I found this from [Hanselman's blog](https://github.com/david-risney/PwshProfile).
IncrementProgress "Terminal-Icons";
if ($Update -eq "On") {
  Write-Verbose "Update Terminal-Icons";
  Install-Module -Name Terminal-Icons -Repository PSGallery -Force -SkipPublisherCheck;
}
Import-Module Terminal-Icons; #
#endregion

#region cd-extras
# [cd-extras](https://github.com/david-risney/PwshProfile) adds different functions for quickly moving between
# directories in your cd history, or directories with shortened names, and others.
IncrementProgress "cd-extras";
if ($Update -eq "On") {
  Write-Verbose "Update cd-extras";
  Install-Module cd-extras -SkipPublisherCheck;
}
Import-Module cd-extras;
setocd ColorCompletion; # Adds color to tab completion

Set-Alias back cd-;
Set-Alias fwd cd+;
#endregion

#region burnttoast
# [BurntToast](https://github.com/Windos/BurntToast) provides PowerShell commands to show OS toast
# notifications. I use it below in the prompt function wrapper.
IncrementProgress "BurntToast";
if ($Update -eq "On") {
  Write-Verbose "Updating BurntToast";
  Install-Module -Name BurntToast -SkipPublisherCheck;
}
Import-Module BurntToast;
#endregion

#region ohmyposh
# [oh-my-posh](https://ohmyposh.dev/docs/) lets you setup a pretty command prompt
IncrementProgress "oh-my-posh";
if ($Update -eq "On") {
  Write-Verbose "Updating OhMyPosh";
  winget install JanDeDobbeleer.OhMyPosh -s winget
}
$ohmyposhConfigPath = (Join-Path $PSScriptRoot "oh-my-posh.json");
oh-my-posh init pwsh --config $ohmyposhConfigPath | Invoke-Expression;
#endregion

#region poshgit
# Why are't I using [posh git](https://github.com/dahlbyk/posh-git)? Posh-Git does two things:
# 1. **Pretty prompt**: I don't need the pretty prompt because I have oh-my-posh which does that and more.
# 2. **Tab completion**: I don't want tab completion because in big projects git is slow and then tab completion is very slow and blocks the prompt.
#
# With PSReadLine's menu completion, I can get some of the same functionality via history completion without the blocking.
# Accordingly, I'm not using it.
#endregion

#region font
# [Nerd fonts](https://ohmyposh.dev/docs/installation/fonts) provide extra symbols useful for making a pretty prompt.
# General purpose icons like the branching icon, or company specific logos
# like the Windows logo, or GitHub logo, and ASCII art sort of icons.
# This is used by oh-my-posh and by Terminal-Icons
if ($Update -eq "On") {
  Write-Verbose "Updating font"; # This maybe doesn't work when first installing gsudo.
  gsudo { oh-my-posh font install CascadiaCode; };
}
#endregion

#region prompt
# Shim the oh-my-posh prompt function to:
#  * add git info to oh-my-posh
#  * show toasts for long running commands
#  * add scrollbar mark support
IncrementProgress "Prompt shim";
Copy-Item Function:prompt Function:poshPrompt;
function prompt {
    $previousSuccess = $?;
    $previousLastExitCode = $global:LASTEXITCODE;
    $lastCommandSucceeded = !$previousLastExitCode -or $previousSuccess;

    try {
      $currentPath = ((Get-Location).Path);
      # oh-my-posh can read environment variables so we put GIT related
      # info into environment variables to be read by our custom prompt
      if ($env:OhMyPoshCustomBranchUriCachePath -ne $currentPath) {
        $env:OhMyPoshCustomBranchUri = Get-GitUri $currentPath;
        $env:OhMyPoshCustomBranchUriCachePath = $currentPath;
      }
    } catch {
      Write-Host ("Custom POSH env var prompt Error: " + $_);
    }

    # Apply the [scrollbar marks](https://learn.microsoft.com/en-us/windows/terminal/tutorials/shell-integration).
    # This notes the start of the prompt
    Write-Host "`e]133;A$([char]07)" -NoNewline;

    if (!$lastCommandSucceeded) {
        cmd /c "exit $previousLastExitCode";
    }

    # Call the wrapped prompt that oh-my-posh created. We use try/catch blocks here
    # because uncaught errors coming from prompt functions are not easy to debug.
    try {
      poshPrompt;
    } catch {
      Write-Host ("POSH Prompt Error: " + $_);
    }

    # This notes the end of the prompt for scrollbar marks.
    Write-Host "`e]133;B$([char]07)" -NoNewLine;

    # Use toasts to notify of completion of long running commands
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

          # This notes the end of the command for scrollbar marks
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
#endregion

#region clickablepaths
# This function takes a URI and text, and returns
# the text formatted with ANSI escape sequence to make
# a link from that.
IncrementProgress "Clickable paths";
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

# For each string that comes through, remove starting and trailing whitespace and colons and
# test if its a path, and if so, make it clickable. Otherwise, return the string.
# Eg to get the output of ripgrep searching for a string but make the paths clickable:
#   rg Format -p | Clickify
function Clickify {
  param(
    [Parameter(ValueFromPipeline)]
    $String
  );

  process {
    if ($String) {
      $trimmedString = $String.Trim();
      $handled = $false;

      if (Test-Path $trimmedString) {
        $fullPath = (Get-Item $trimmedString).FullName;
        Format-TerminalClickableString $fullPath $trimmedString;
        $handled = $true;
      }

      if (!$handled) {
        # First remove any ANSI sequences from $String
        $StrippedString = $String -replace "\x1B\[[0-?]*[ -/]*[@-~]", "";
        # And also the \x1B]8;...\x1B\ style sequences
        $StrippedString = $StrippedString -replace "\x1B\]8;.*?\x1B\\";

        # Use regexp to find all posible absolute and relative paths in the string
        $relativePathWithSpaceRegex = "([A-Za-z0-9 '`".+\-\\\/_]+)";
        $relativePathWithoutSpaceRegex = "([A-Za-z0-9 '`".+\-\\\/_]+)";
        $absolutePathRegex = "([A-Za-z]:\\[A-Za-z0-9 '`".+\-\\\/_]+)";

        $regexs = @($relativePathWithSpaceRegex, $relativePathWithoutSpaceRegex, $absolutePathRegex);
        $matches = $regexs | %{
          $regex = $_;
          [regex]::Matches($StrippedString, $regex);
        };
        $uniqueValues = $matches.Value | Sort Length -Uniq -Desc;
        $uniqueValues | ?{ $_.Trim().Length -gt 0 } | ?{ Test-Path $_ } | %{
          $curValue = $_;
          # If the current value is a substring of something else then its
          # already covered and we can skip it.
          if (!($uniqueValues | ?{ $_ -ne $curValue -and $_.Contains($curValue) })) {
            $String = $String.Replace($curValue, (Format-TerminalClickableString $curValue $curValue));
          }
        }
        $String;
      }
    } else {
      "";
    }
  }
}

# Run after Terminal-Icons to have both terminal-icons and clickable
# paths.
$terminableClickableFormatPath = (Join-Path $PSScriptRoot "TerminalClickable.format.ps1xml");
Update-FormatData -PrependPath $terminableClickableFormatPath;
#endregion

#region terminalsettings
# Merge terminal settings JSON into the various places Windows terminal stores its settings
IncrementProgress "Applying Terminal settings";
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
#endregion

#region z
# A port of the z bash script - [z](https://github.com/badmotorfinger/z) lets you quickly jump between
# directories in your cd history.
IncrementProgress "z";
if ($Update -eq "On") {
  Write-Verbose "Updating z";
  install-module z -AllowClobber -SkipPublisherCheck;
}
Import-Module z;
#endregion

#region bat
# bat is a fancy version of cat / more / less with syntax highlighting
# If you get 'invalid charset name' make sure you don't have an old less.exe in your PATH
IncrementProgress "bat";
if (($Update -eq "On")) { # -or !(Get-Command bat -ErrorAction Ignore)) {
  Write-Verbose "Updating bat";
  winget install sharkdp.bat;
  # bat relies on less for paging
  Write-Verbose "Updating less";
  winget install jftuga.less;

  # Install ov https://github.com/noborus/ov?tab=readme-ov-file#winget(windows)
  winget install -e --id noborus.ov

  # Install delta https://github.com/dandavison/delta?tab=readme-ov-file
  winget install dandavison.delta

  Write-Verbose "Updating glow";
  winget install charmbracelet.glow;
}
# Use bat --list-themes to see all themes
# And then set the theme you want using:
$env:BAT_THEME = "ansi";

# Use some specific command line params with less:
# -r - don't escape control characters - this includes ANSI escape sequences for colors and links.
# -F - quit if less than one screen
# -X - don't clear the screen on exit
# --use-color - use color
# --color=P - change the prompt color
# --prompt= - change the prompt
# Disable this for now. Other things like bat and delta get confused about encodings
# $prev = [Console]::OutputEncoding;
# [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new();
# $lessOhMyPoshJson = (Join-Path $PSScriptRoot "less-oh-my-posh.json");
# $env:LESS = ("-rFX --use-color --color=P-- --prompt=" + (oh-my-posh print primary --config $lessOhMyPoshJson).Replace("\", "\\").Replace(":", "\:").Replace("?", "\?").Replace(".", "\.") + '$');
# [Console]::OutputEncoding = $prev;

$env:BAT_PAGER = ("less " + $env:LESS);

# Delta config
$deltaArgs = "--line-numbers --hyperlinks --hyperlinks-file-link-format=`"vscode://file/{path}:{line}`" --hunk-header-decoration-style=`"bold`" --file-decoration-style=`"ol white bold`""
git config --global core.pager "delta $deltaArgs" 2> $null;
git config --global interactive.diffFilter "delta --color-only $deltaArgs" 2> $null;
git config --global delta.navigate true 2> $null;
git config --global merge.conflictStyle zdiff3 2> $null;
$gitRemote = git remote get-url origin 2> $null;
if ($gitRemote) {
  if ($gitRemote -eq "https://chromium.googlesource.com/chromium/src.git") {
    $deltaArgs += ' --hyperlinks-commit-link-format="https://source.chromium.org/chromium/chromium/src/+/{commit}"'
  }
  git config core.pager "delta $deltaArgs" 2> $null;
  git config interactive.diffFilter "delta --color-only $deltaArgs" 2> $null;
}

function BatGlowHelper {
  param(
    [string]$Path
  );
  # Format-TerminalClickableString $Path "$Path";

  if ($Path.EndsWith(".md")) {
    $glowConfig = (Join-Path $PSScriptRoot "glow.yml");
    glow --config $glowConfig $Path;
  } else {
    bat $Path;
  }
}

# I'm never going to remember to use bat because my fingers
# are too used to typing more. So just alias more to bat.
# Get-Content (gc) is the powershell version of cat that won't
# add line numbers and extra decorations and can handle
# PowerShell specific paths like env: and function:
Set-Alias more BatGlowHelper;
#endregion

#region asyncupdate
if ($Update -eq "Async") {
  $lastAsyncUpdatePath = (Join-Path "~" "pwsh-profile-last-async-update.txt");
  $lastAsyncUpdate = $null;

  if (Test-Path $lastAsyncUpdatePath) {
    $lastAsyncUpdate = (Get-Item $lastAsyncUpdatePath).LastWriteTime;
  }

  if (!($lastAsyncUpdate) -or ((Get-Date) -gt $lastAsyncUpdate.AddDays(7))) {
    # Touch before starting update because the update may take a long time.
    touch $lastAsyncUpdatePath;

    $userProfilePath = (Join-Path $PSScriptRoot "profile.ps1");

    Write-Host "Starting async update...";
    [void](Start-Job -Name ProfileAsyncInstallOrUpdate -ScriptBlock {
      param($userProfilePath);
      if (Get-Command pwsh -ErrorAction Ignore) {
        gsudo { Start-Process pwsh -ArgumentList "C:\users\davris\PwshProfile\profile.ps1 -update on -verbose" }
      } else {
        gsudo { Start-Process powershell -ArgumentList "C:\users\davris\PwshProfile\profile.ps1 -update on -verbose" }
      }
      sudo .$userProfilePath -Update On -Verbose;
      $success = $LASTEXITCODE -eq 0 -and $?;
      New-BurntToastNotification -Text "Profile Update",$success;
    } -ArgumentList $userProfilePath);
  }
}
#endregion

#region miscupdate
if ($Update -eq "On") {
  IncrementProgress "Update various apps";

  Write-Verbose "Update ripgrep";
  winget install BurntSushi.ripgrep.MSVC;
  Write-Verbose "Install fd";
  winget install sharkdp.fd;
  Write-Verbose "Install PSGitHubSearch";
  Install-Module -Name PSGitHubSearch -SkipPublisherCheck;
  Write-Verbose "Update powershell";
  winget install --id Microsoft.Powershell --source winget;
  Write-Verbose "Update git";
  winget install git --source winget;
  Write-Verbose "Update remote desktop";
  winget install --id Microsoft.RemoteDesktopClient;
  # The following installs could take a while and they aren't
  # requirements for anything else in this script
  # So run them in a different command prompt
  Write-Verbose "Update powertoys";
  winget install Microsoft.PowerToys;
  Write-Verbose "Update vscode";
  winget install Microsoft.VisualStudioCode;
  Write-Verbose "Update vs";
  winget install Microsoft.VisualStudio.2022.Enterprise;

  winget update --all;
}
#endregion

IncrementProgress "Copying VSCode tasks.json";
Copy-Item (Join-Path $PSScriptRoot "vscode-tasks.json") $env:APPDATA\code\user\tasks.json;

IncrementProgress "Done";

#region winfetch
# WinFetch basically just looks cool
# We run it last AFTER all the IncrememntProgress calls because the
# PowerShell progress indicator clears the WinFetch logo display
if ($WinFetch -eq "Auto") {
  if ((Get-Process -Id $PID).Parent.ProcessName -ne "pwsh") {
    $WinFetch = "On";
  } else {
    $WinFetch = "Off";
  }
}

if ($WinFetch -eq "On") {
  # Invoke-WebRequest "https://raw.githubusercontent.com/lptstr/winfetch/master/winfetch.ps1" -OutFile .\winfetch.ps1 -UseBasicParsing
  $gifContainerPath = (Join-Path $PSScriptRoot "gifs");
  $gifFileOptions = Get-ChildItem $gifContainerPath -File -Filter *.ps1;
  # pick a random gif file to use
  $logoPs1File = $gifFileOptions | Get-Random;
  $logoGifFile = (Join-Path $PSScriptRoot "gifs\$($logoPs1File.BaseName).gif");

  .($logoPs1File.FullName);
  $winfetchPath = (Join-Path $PSScriptRoot "winfetch.ps1");
  $winfetchConfigPath = (Join-Path $PSScriptRoot "winfetch-config.ps1");
  $winfetchLogoPath = $logoGifFile;
  .$winfetchPath -config $winfetchConfigPath -image $winfetchLogoPath;
}
#endregion

# ## Todo
# * Pull out prompt add-ons into separate functions
# * Change winfetch logo for my edge repos
# * Better icon for toast
