$sw = [Diagnostics.Stopwatch]::StartNew()
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$global:progressIdx = 0;
# Find via (findstr /c "^IncrementProgress" .\profile.ps1).Count
$global:maxProgress = 16; # The count of IncrementProgress calls in this file.

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
  [void](Start-Job -ScriptBlock { ninja -C out\debug_x64 -t compdb cxx > out\debug_x64\compile_commands.json ; Show-Toast "Completed compdb update" });
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
  param(
    $ModuleName,
    [switch] $Async);

  if (!(Get-Module $ModuleName)) {
    Import-Module $ModuleName -ErrorAction Ignore;

    if (!(Get-Module $ModuleName)) {
      [void](Start-Job -ScriptBlock {
        Write-Output "Install $ModuleName";

        if ((Get-PSRepository PSGallery).InstallationPolicy -ne "Trusted") {
          Set-PSRepository PSGallery -InstallationPolicy Trusted;
        }

        if ((Get-Command install-module)[0].Parameters["AllowPrerelease"]) {
          Install-Module -Name $ModuleName -Force -Repository PSGallery -AllowPrerelease -Scope CurrentUser;
        } else {
          Install-Module -Name $ModuleName -Force -Repository PSGallery -Scope CurrentUser;
        }
        Import-Module $ModuleName;
      });
    } else {
      $tryUpdate = $true;
    }
  } else {
    $tryUpdate = $true;
  }

  if ($tryUpdate) {
    [void](Start-Job -ScriptBlock { Update-Module $ModuleName -Scope CurrentUser; });
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

  if (!(Get-Command $ModuleName)) {
    winget list $ModuleName | Out-Null;
    $found = ($LastExitCode -eq 0);

    if (!$found) {
      winget install $ModuleName;
    } else {
      $tryUpdate = $true;
    }
  } else {
    $tryUpdate = $true;
  }

  if ($tryUpdate) {
    [void](Start-Job -ScriptBlock {
      if (!$Exact) {
        winget upgrade $ModuleName;
      } else {
        winget upgrade $ModuleName -e;
      }
    });
  }
}

IncrementProgress "Updating profile script"
# Update the profile scripts
[void](Start-Job -ScriptBlock {
  pushd ~\PwshProfile;
  # Use ff-only to hopefully avoid cases where merge is required
  git pull --ff-only
});

IncrementProgress "PowerShell";
UpdateOrInstallWinget PowerShell -Exact -Async;
IncrementProgress "PowerShellGet";
UpdateOrInstallModule PowerShellGet;
IncrementProgress "PSReadLine";
UpdateOrInstallModule PSReadLine; # https://github.com/PowerShell/PSReadLine
IncrementProgress "Terminal-Icon";
UpdateOrInstallModule Terminal-Icons; # https://www.hanselman.com/blog/take-your-windows-terminal-and-powershell-to-the-next-level-with-terminal-icons
IncrementProgress "cd-extras";
UpdateOrInstallModule cd-extras; # https://github.com/nickcox/cd-extras
IncrementProgress "BurntToast";
UpdateOrInstallModule BurntToast -Async; # https://github.com/Windos/BurntToast
IncrementProgress "oh-my-posh";
UpdateOrInstallWinget -ModuleName oh-my-posh -PackageName JanDeDobbeleer.OhMyPosh; # https://ohmyposh.dev/docs/pwsh/

# IncrementProgress "Posh-Git";
# UpdateOrInstallModule Posh-Git; # https://github.com/dahlbyk/posh-git

IncrementProgress "Nerd font check";
# https://ohmyposh.dev/docs/installation/fonts
if (!(Get-ChildItem C:\windows\fonts\CaskaydiaCoveNerdFont*)) {
  Write-Error "Cascadia nerd font not found. Run the following from admin`n`toh-my-posh font install CascadiaCode;"
}

IncrementProgress "PSReadLineOptions init";
Set-PSReadLineOption -PredictionSource History;
Set-PSReadLineOption -PredictionViewStyle ListView;
Set-PSReadLineOption -EditMode Windows;
Set-PSReadLineKeyHandler Tab MenuComplete; # Tab completion gets a menu

IncrementProgress "oh-my-posh init";
$ohmyposhConfigPath = (Join-Path $PSScriptRoot "oh-my-posh.json");
oh-my-posh init pwsh --config $ohmyposhConfigPath | Invoke-Expression;

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
    $previousLastExitCode = $global:LASTEXITCODE;

    try {
      $currentPath = ((Get-Location).Path);
      if ($env:OhMyPoshCustomBranchUriCachePath -ne $currentPath) {
        $env:OhMyPoshCustomBranchUri = Get-GitUri $currentPath;
        $env:OhMyPoshCustomBranchUriCachePath = $currentPath;
      }
    } catch {
      Write-Host ("Custom POSH env var prompt Error: " + $_);
    }

    if (!$previousLastExitCode) {
        cmd /c "exit $previousLastExitCode";
    }

    try {
      poshPrompt;
    } catch {
      Write-Host ("POSH Prompt Error: " + $_);
    }

    try {
      $lastCommandFailed = ($LastExitCode -ne $null -and $LastExitCode -ne 0) -or !$?;
      $lastCommandTookALongTime = $false;
      $lastCommandTime = 0;

      $h = (Get-History);
      if ($h.length -gt 0) {
          $lh = $h[$h.length - 1];
          $lastCommandTime = $lh.EndExecutionTime - $lh.StartExecutionTime;
          $lastCommandTookALongTime = $lastCommandTime.TotalSeconds -gt 10;
          if ($lh.ExecutionStatus -eq "Completed" -and $lastCommandTookALongTime) {
              $status = "Success: ";
              if ($lastCommandFailed) {
                $status = "Failed: ";
              }
              New-BurntToastNotification -Text $status,($lh.CommandLine);
          }
      }
    } catch {
      Write-Host ("CDHistory Prompt Error: " + $_);
    }
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

IncrementProgress "Done";