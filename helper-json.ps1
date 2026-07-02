
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

# Write text to a file by first writing to a temp file in the same directory and
# then atomically moving it into place. This avoids leaving a truncated/partial
# destination file if the write is interrupted or if two processes race to update
# the same file (which can, for example, wipe Windows Terminal's profiles.list and
# reset profiles to defaults).
function Out-FileAtomic ($content, $outFilePath, $encoding = "Utf8") {
  $outDir = Split-Path -Parent $outFilePath;
  if (!$outDir) { $outDir = "."; }
  $tempPath = Join-Path $outDir ([System.IO.Path]::GetRandomFileName());
  try {
    $content | Out-File $tempPath -Encoding $encoding;
    # Move-Item -Force replaces the destination atomically on the same volume.
    Move-Item -LiteralPath $tempPath -Destination $outFilePath -Force;
  } finally {
    if (Test-Path -LiteralPath $tempPath) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue;
    }
  }
}

function MergeJsonFilesAndStrings ($inJsonFilePaths, $inJsonStrings, $outJsonFilePath, $encoding = "Utf8") {
  $inJson = @($inJsonFilePaths | ForEach-Object { 
    Get-Content $_ -Raw;
  }) + @($inJsonStrings);
  $outJson = MergeJson $inJson;
  Out-FileAtomic $outJson $outJsonFilePath $encoding;
}

function MergeJsonFiles ($inJsonFilePaths, $outJsonFilePath, $encoding = "Utf8") {
  MergeJsonFilesAndStrings @($inJsonFilePaths) @() $outJsonFilePath $encoding;
}

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

  $outJson = $json | ConvertTo-Json -Depth 32;
  Out-FileAtomic $outJson $settingsPath;
}
