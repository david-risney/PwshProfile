$sw = [Diagnostics.Stopwatch]::StartNew()
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$global:progressIdx = 0;
$global:maxProgress = 12;

function IncrementProgress {
  param($Name);
  ++$global:progressIdx;
  Write-Verbose ($Name + " (" + $swTotal.Elapsed.ToString() + ", " + $sw.Elapsed.ToString() + ")");
  $sw.Restart();

  Write-Progress -Activity "Loading Profile" -Status $Name -PercentComplete (($global:progressIdx * 100) / ($global:maxProgress));
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

# Update the profile scripts
[void](Start-Job -ScriptBlock {
  pushd ~\PwshProfile;
  # Use ff-only to hopefully avoid cases where merge is required
  git pull --ff-only
});

if ((Get-PSRepository PSGallery).InstallationPolicy -ne "Trusted") {
  Set-PSRepository PSGallery -InstallationPolicy Trusted;
}

IncrementProgress "PowerShell";
UpdateOrInstallWinget PowerShell -Exact
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

# https://ohmyposh.dev/docs/installation/fonts
# https://github.com/microsoft/cascadia-code/releases
# if (!(Get-ChildItem C:\windows\fonts\cascadia*)) {
#   Write-Error "Install the Cascadia Code font https://github.com/microsoft/cascadia-code/releases"
# }

IncrementProgress "PSReadLineOptions init";
Set-PSReadLineOption -PredictionSource History;
Set-PSReadLineOption -PredictionViewStyle ListView;
Set-PSReadLineOption -EditMode Windows;
Set-PSReadLineKeyHandler Tab MenuComplete; # Tab completion gets a menu

IncrementProgress "oh-my-posh init";
$ohmyposhConfigPath = (Join-Path $PSScriptRoot "oh-my-posh.json");
oh-my-posh init pwsh --config $ohmyposhConfigPath | Invoke-Expression;

IncrementProgress "toast prompt";
Copy-Item Function:prompt Function:poshPrompt;
function prompt {
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

function Auto-Vpn {
  $ensureVpnConnectionScriptBlock = {
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

      $changed = (EnsureVpnConnection);
      if ($changed) {
          Write-Host (GetVpnStatus);
      }
  };

  $sysevent = [microsoft.win32.systemevents];
  $sessionSwitchEvent = Register-ObjectEvent -InputObject $sysevent -EventName "SessionSwitch" -Action $ensureVpnConnectionScriptBlock;

  while ($true) {
      .$ensureVpnConnectionScriptBlock;

      Start-Sleep -Seconds (60 * 0.5);

      Receive-Job $sessionSwitchEvent;
  }
}

function WebView2Docs {
  # WebView2-Docs.ps1 takes a WebView2 API name, and an optional parameter to say which language
  # to use (WinRT, .NET, Win32), and opens the corresponding WebView2 API documentation page in
  # the default browser.
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
      $linkProperty = "`e]8;;$($_.link)`e\$($_.title)`e]8;;`e\";
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