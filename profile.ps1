[CmdletBinding()]
param(
  [ValidateSet("On", "Off", "Async")] $Update = "Async",
  [ValidateSet("On", "Off", "Auto")] $WinFetch = "Auto");

. (Join-Path $PSScriptRoot "helper-progress.ps1");

# Find via (findstr /c "^IncrementProgress" .\profile.ps1).Count
$global:maxProgress = 17; # The count of IncrementProgress calls in this file.

if ($Update -eq "On") {
  $global:maxProgress += 4;
}

# Store an environment variable for the path to this folder
$env:PwshProfilePath = $PSScriptRoot;

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

# Avoid some python errors moving between old and new verions
$env:PYTHONIOENCODING = "UTF-8";

# This is all slow and so only do it when Update is set.
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

#region profile update
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
#endregion

#region update powershellget
if ($Update -eq "On") {
  IncrementProgress "Update PowerShellGet";
  Write-Verbose "Update PowerShellGet";
  Install-Module -Name PowerShellGet -Force -Repository PSGallery -AllowPrerelease -Scope CurrentUser;
}
#endregion

#region PSReadLine
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
#endregion

#region terminal-icons
IncrementProgress "Terminal-Icons";
# Terminal-Icons adds "icons" and coloring to default dir output
# in PowerShell.
if ($Update -eq "On") {
  Write-Verbose "Update Terminal-Icons";
  Install-Module -Name Terminal-Icons -Repository PSGallery;
}
Import-Module Terminal-Icons; # https://www.hanselman.com/blog/take-your-windows-terminal-and-powershell-to-the-next-level-with-terminal-icons
#endregion

#region cd-extras
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
#endregion

#region burnttoast
IncrementProgress "BurntToast";
# BurntToast provides PowerShell commands to show OS toast
# notifications
if ($Update -eq "On") {
  Write-Verbose "Updating BurntToast";
  Install-Module -Name BurntToast
}
Import-Module BurntToast; # https://github.com/Windos/BurntToast
#endregion

#region ohmyposh
IncrementProgress "oh-my-posh";
# oh-my-posh lets you setup a pretty command prompt
# UpdateOrInstallWinget -ModuleName oh-my-posh -PackageName JanDeDobbeleer.OhMyPosh; # https://ohmyposh.dev/docs/pwsh/
if ($Update -eq "On") {
  Write-Verbose "Updating OhMyPosh";
  winget install JanDeDobbeleer.OhMyPosh -s winget
}
$ohmyposhConfigPath = (Join-Path $PSScriptRoot "oh-my-posh.json");
oh-my-posh init pwsh --config $ohmyposhConfigPath | Invoke-Expression;
#endregion

#region poshgit
# IncrementProgress "Posh-Git";
# Why are't I using posh git? Posh-Git does two things: 
# (1) a pretty prompt 
# I don't need the pretty prompt because I have oh-my-posh which does that and more.
# (2) tab completion. 
# I don't want tab completion because in big projects git is slow and then tab completion is very slow and blocks the prompt.
# With PSReadLine's menu completion, I can get some of the same functionality via history completion without the blocking.
# Accordingly, this is disabled
# UpdateOrInstallModule Posh-Git; # https://github.com/dahlbyk/posh-git
#endregion

#region font
# Nerd fonts provide extra symbols useful for making a pretty prompt.
# General purpose icons like the branching icon, or company specific logos
# like the Windows logo, or GitHub logo, and ASCII art sort of icons.
# This is used by oh-my-posh and by Terminal-Icons
# https://ohmyposh.dev/docs/installation/fonts
if ($Update -eq "On") {
  # This maybe doesn't work when first installing gsudo.
  Write-Verbose "Updating font";
  gsudo { oh-my-posh font install CascadiaCode; };
}
#endregion

#region prompt
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
#endregion

#region clickablepaths
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
#endregion

#region terminalsettings
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
#endregion

#region z
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
#endregion

#region bat
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
#endregion

#region asyncupdate
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

  winget update --all;
}
#endregion

IncrementProgress "Copying VSCode tasks.json";
Copy-Item (Join-Path $PSScriptRoot "tasks.json") $env:APPDATA\code\user\tasks.json;

IncrementProgress "Done";

#region winfetch
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
#endregion

# Ideas:
# * Fix terminal-icons
# * Change winfetch logo for my edge repos
# * Better icon for toast
# * Consider extracting grouped chunks out into modules
# * Put async update code into one big sudo call
# * Check out https://github.com/dandavison/delta
