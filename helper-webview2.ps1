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

function GetEdgeProcesses {
    [cmdletbinding()]
    param(
        [string] $CommandLineMatch = "",
        [ValidateSet("All", "Canary", "Dev", "Beta", "Stable")]
            [string[]] $Channels = @("All"),
        [ValidateSet("Edge", "WebView2")]
            [string[]] $HostKinds = @("Edge", "WebView2"),
        [ValidateSet("All", "browser", "crashpad-handler", "gpu-process", "renderer", "utility")]
            [string[]] $ProcessKinds = @("All"),
        [switch] [alias("np")] $NoPretty
    );

    # Get-Process's CommandLine property is slow because it uses individual calls to Get-CimInstance.
    # We can speed it up a bunch by running Get-CimInstance ourselves for all the processes we're
    # interested in.
    $cimProcesses = @();
    $processes = @();
    if ($HostKinds.Contains("Edge")) {
        $processes += Get-Process msedge;
        $cimProcesses += Get-cimInstance Win32_Process -Filter "Name='msedge.exe'";
    }
    if ($HostKinds.Contains("WebView2")) {
        $processes += Get-Process msedgewebview2;
        $cimProcesses += Get-cimInstance Win32_Process -Filter "Name='msedgewebview2.exe'";
    }

    $processes | ForEach-Object {
        $currentProcess = $_;

        $MainModulePath = $_.MainModule.FileName.ToLower();
        $currentProcess | Add-Member MainModulePath $MainModulePath;

        $HostKind = "Edge";
        if ($_.ProcessName -eq "msedge") {
            $HostKind = "Edge";
        } else {
            $HostKind = "WebView2";
        }
        $currentProcess | Add-Member HostKind $HostKind;

        $Channel = "Unknown";
        if ($MainModulePath.Contains("\edge sxs\")) {
            $Channel = "Canary";
        } elseif ($MainModulePath.Contains("\edge beta\")) {
            $Channel = "Beta";
        } elseif ($MainModulePath.Contains("\edge dev\")) {
            $Channel = "Dev";
        } elseif ($MainModulePath.Contains("\edge\")) {
            $Channel = "Stable";
        } elseif ($MainModulePath.Contains("\edgewebview\")) {
            $Channel = "Stable";
        }
        $currentProcess | Add-Member Channel $Channel;

        $currentProcessKind = "browser";
        $currentCommandLine = ($cimProcesses | Where-Object { 
            $_.ProcessId -eq $currentProcess.Id
        }).CommandLine;

        if ($currentCommandLine -match "--type=([^ ]+)") {
            $currentProcessKind = $Matches[1];
        }

        $version = (Get-Item $MainModulePath).VersionInfo.FileVersion;

        $currentProcess | Add-Member ProcessKind $currentProcessKind;
        $currentProcess | Add-Member -Force EdgeCommandLine $currentCommandLine;
        $currentProcess | Add-Member -Force Version $version;
    }

    $processes = $processes | Where-Object {
        $currentProcess = $_;
        $channelMatches = $Channels -contains $currentProcess.Channel -or $Channels -contains "All";
        $edgeProcessTypeMatches = $ProcessKinds -contains $currentProcess.ProcessKind -or $ProcessKinds -contains "All";
        $commandLineMatches = $CommandLineMatch -eq "" -or $currentProcess.EdgeCommandLine -match $CommandLineMatch;

        $channelMatches -and $edgeProcessTypeMatches -and $commandLineMatches;
    };

    if ($NoPretty) {
        $processes;
    } else {
        $processes | `
            Sort-Object HostKind,MainModulePath,Version,Channel,ProcessKind,Id | `
            Format-Table HostKind,Version,Channel,ProcessKind,Id,EdgeCommandLine;
    }
}
New-Alias -f Get-EdgeProcesses GetEdgeProcesses;