$sw = [Diagnostics.Stopwatch]::StartNew()
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$global:progressIdx = 0;
# Find via (findstr /c "^IncrementProgress" .\profile.ps1).Count
$global:maxProgress = 15; # The count of IncrementProgress calls in this file.

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

$env:PATH = ($env:PATH.split(";") + @(Get-ChildItem ~\*bin) + @(Get-ChildItem ~\*bin\* -Directory) + @(Get-ChildItem ~\*bin\*bin -Directory)) -join ";";
if (Test-Path out\debug_x64) {
    [void](Start-Job -ScriptBlock {
        ninja -C out\debug_x64 -t compdb cxx > out\debug_x64\compile_commands.json ;
        Show-Toast "Completed compdb update"
    });
}

function cd- { cd - };

Set-Alias back cd-
Set-Alias fwd cd+
New-Alias cds Set-LocationSet

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

function Set-LocationRoot {
    $root = (Get-LocationRoot);
    if ((Get-Location).Path -eq $root) {
        cd ..
        $root = (Get-LocationRoot);
    }
    Set-Location $root;
}

new-alias \ Set-LocationRoot

$env:PYTHONIOENCODING = "UTF-8"

function UpdateOrInstallModule {
  param($ModuleName);

  Import-Module $ModuleName -ErrorVariable errorVariable -ErrorAction SilentlyContinue;
  # if we fail to import, we need to block and install
  if ($errorVariable) {
    Write-Host "Couldn't import $ModuleName, trying to install first..."
    if ((Get-PSRepository PSGallery).InstallationPolicy -ne "Trusted") {
      Set-PSRepository PSGallery -InstallationPolicy Trusted;
    }
    if ((Get-Command install-module)[0].Parameters["AllowPrerelease"]) {
      Install-Module -Name $ModuleName -Force -Repository PSGallery -AllowPrerelease -Scope CurrentUser;
    } else {
      Install-Module -Name $ModuleName -Force -Repository PSGallery -Scope CurrentUser;
    }
    Import-Module $ModuleName;
  } else {
    [void](Start-Job -ScriptBlock { 
      $args[0];
      Update-Module $args[0] -Scope CurrentUser;
    } -ArgumentList @($ModuleName));
  }
}

function UpdateOrInstallWinget {
  param(
    $ModuleName,
    $PackageName,
    [switch] $Exact);
  if ($PackageName -eq "") {
    $PackageName = $ModuleName;
  }
  $tryUpdate = $false;

  # Blocking install if its not here
  if (!(Get-Command $ModuleName)) {
    winget install $ModuleName;
  } else {
    # Otherwise, non-blocking update
    [void](Start-Job -ScriptBlock {
      $args[0],$args[1];
      if (!$args[1]) {
        winget upgrade $args[0];
      } else {
        winget upgrade $args[0] -e;
      }
    } -ArgumentList @($ModuleName,$Exact));
  }
}

IncrementProgress "Updating profile script"
# Update the profile scripts
[void](Start-Job -ScriptBlock {
  Push-Location ~\PwshProfile;
  # Use ff-only to hopefully avoid cases where merge is required
  git pull --ff-only
});

# Move these to a separate install / update script
# IncrementProgress "PowerShell";
# UpdateOrInstallWinget PowerShell -Exact;
# IncrementProgress "PowerShellGet";
# UpdateOrInstallModule PowerShellGet;
IncrementProgress "PSReadLine";
Import-Module PSReadLine; # https://github.com/PowerShell/PSReadLine
IncrementProgress "PSReadLineOptions init";
Set-PSReadLineOption -PredictionSource History;
Set-PSReadLineOption -PredictionViewStyle ListView;
Set-PSReadLineOption -EditMode Windows;
Set-PSReadLineKeyHandler Tab MenuComplete; # Tab completion gets a menu. Must do before importing cd-extras

IncrementProgress "Terminal-Icons";
Import-Module Terminal-Icons; # https://www.hanselman.com/blog/take-your-windows-terminal-and-powershell-to-the-next-level-with-terminal-icons

IncrementProgress "cd-extras";
Import-Module cd-extras; # https://github.com/nickcox/cd-extras

IncrementProgress "BurntToast";
Import-Module BurntToast; # https://github.com/Windos/BurntToast


# IncrementProgress "oh-my-posh";
# UpdateOrInstallWinget -ModuleName oh-my-posh -PackageName JanDeDobbeleer.OhMyPosh; # https://ohmyposh.dev/docs/pwsh/
IncrementProgress "oh-my-posh init";
$ohmyposhConfigPath = (Join-Path $PSScriptRoot "oh-my-posh.json");
oh-my-posh init pwsh --config $ohmyposhConfigPath | Invoke-Expression;


# Why are't I using posh git? Posh-Git does two things: (1) a pretty prompt and (2) tab completion. 
# I don't need the pretty prompt because I have oh-my-posh which does that and more.
# I don't want tab completion because in big projects git is slow and then tab completion is very slow and blocks the prompt.
# With PSReadLine's menu completion, I can get some of the same functionality via history completion without the blocking.
# IncrementProgress "Posh-Git";
# UpdateOrInstallModule Posh-Git; # https://github.com/dahlbyk/posh-git

IncrementProgress "Nerd font check";
# https://ohmyposh.dev/docs/installation/fonts
if (!(Get-ChildItem C:\windows\fonts\CaskaydiaCoveNerdFont*)) {
  Write-Error "Cascadia nerd font not found. Run the following from admin`n`toh-my-posh font install CascadiaCode;"
}


function Get-GitUri {
  param($Path);

  $Path = (gi $Path).FullName.Replace("\", "/");

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

IncrementProgress "prompt shim for toast and oh-my-posh custom env vars";
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

IncrementProgress "clickable paths";
function Format-TerminalClickableString {
  param(
    $Uri,
    $DisplayText);

  $clickableFormatString = "`e]8;;{0}`e\{1}`e]8;;`e\"
  $formattedString = ($clickableFormatString -F ($Uri,$DisplayText));
  $formattedString;
}

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

$terminableClickableFormatPath = (Join-Path $PSScriptRoot "TerminalClickable.format.ps1xml");
Update-FormatData -PrependPath $terminableClickableFormatPath;

IncrementProgress "Define helpful functions";

function AutoConnect-Vpn {
  function GetVpnStatus {
      $vpns = Get-VpnConnection;
      $date = (date);
      $vpns | %{
          New-Object -TypeName PSObject -Property @{'Date'=$date; 'Name'=$_.Name; 'ConnectionStatus'=$_.ConnectionStatus};
      }
  }

  function EnsureVpnConnection {
      $changed = $false;
      $vpns = GetVpnStatus;
      Write-Host ($vpns);
      $vpns | %{
          if ($_.ConnectionStatus -eq "Disconnected") {
              rasdial $_.Name;
              $changed = $true;
              Start-Sleep -Seconds 5;
          }
      }

      $changed;
  }


  while ($true) {
      $changed = (EnsureVpnConnection);
      if ($changed) {
          Write-Host (GetVpnStatus);
      }

      Start-Sleep -Seconds (60 * 0.5);
  }
}

function Launch-WebView2Docs {
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

function Git-RebaseOnto {
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
      $BranchToRebase = git branch | ?{ $_.StartsWith("*") } | %{ $_.substring(2) }
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

# https://github.com/badmotorfinger/z
# install-module z -AllowClobber
IncrementProgress "z";
Import-Module z;

IncrementProgress "Done";
if ((ps -Id $PID).Parent.ProcessName -eq "WindowsTerminal") {
  # Invoke-WebRequest "https://raw.githubusercontent.com/lptstr/winfetch/master/winfetch.ps1" -OutFile .\winfetch.ps1 -UseBasicParsing
  $winfetchPath = (Join-Path $PSScriptRoot "winfetch.ps1");
  $winfetchConfigPath = (Join-Path $PSScriptRoot "winfetch-config.ps1");
  $winfetchLogoPath = (Join-Path $PSScriptRoot "logo.png");
  .$winfetchPath -config $winfetchConfigPath -image $winfetchLogoPath;
}

# Also install bat
# If you get 'invalid charset name' make sure you don't have an old less.exe in your PATH
if (!(Get-Command bat)) {
  winget install sharkdp.bat;
  # bat relies on less for paging
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
New-Alias more bat;

# A version of which that says the path to the command but
# also handles PowerShell specific paths things like alias:
# and function:
function which {
  Get-Command -All $args[0] | %{
    if ($_.Source.Length -gt 0) {
      $_.Source;
    } else {
      ("" + $_.CommandType) + ":" + $_.Name;
    }
  }
}

# Fancy ninja status
if (Get-Command goma_ctl -ErrorAction Ignore) {
  # See https://chromium.googlesource.com/infra/goma/client/+/refs/heads/main/client/goma_ctl.py
  $gomaUri = @((goma_ctl status) | %{ if ($_ -match "(http[^ ]+)") { $matches[1] } })[0];
  # The first ` e escape sequence changes to blue on white text
  # The second changes the text to be a link to the goma uri
  # The third closes the link
  # The fourth resets the color
  # See https://ninja-build.org/manual.html#:~:text=control%20its%20behavior%3A-,NINJA_STATUS,-%2C%20the%20progress%20status
  # for more info on the percent escape codes for NINJA_STATUS
  $env:NINJA_STATUS = "`e[1;37;44m[`e]8;;$gomaUri`e\%r running, %f/%t @ %c/s %o/s : %es`e]8;;`e\]`e[0m ";
}

# Ideas:
# * Fix terminal-icons
# * Add -update parameter and run it async at the end
# * Merge install.ps1 with this script, do I need a separate -install parameter for anything that would take too long otherwise?  # * bat has syntax highlighting for git log. Can you add linkifying to commits with that and make it replace git log?
# * Change winfetch logo for my edge repos
# * Better icon for toast
# * Add more comments and group sections of profile.ps1 together
# * Consider extracting grouped chunks out into modules
# * Check out https://github.com/dandavison/delta
# * Check out ripgrep