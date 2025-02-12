
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

# Takes a script block and an optional time interval and runs
# the script block every time interval and showing the diff
# between the last run and the current run.
# Example of calling Watch-Script:
# Watch-Script { Get-Process | Sort-Object -Property CPU -Descending | Select-Object -First 5 } -Interval 1 -ShowDiff $true
function Watch-Script {
  param($ScriptBlock, $Interval = 1, $ShowDiff = $false);
  $last = & $ScriptBlock;
  while ($true) {
    Start-Sleep -Seconds $Interval;
    $current = & $ScriptBlock;
    # Use Compare-Object to show the difference between the last
    # and current output.
    if ($ShowDiff) {
      Compare-Object -ReferenceObject $last -DifferenceObject $current;
    } else {
      clear;
      $current;
    }
    $last = $current;
  }
}

# RipGrep based Find and Replace function.
function Find-Replace {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)] $Find, 
    [Parameter(Mandatory=$true)] $Replace, 
    [Parameter(Mandatory=$false)] $Files,
    [switch] $WhatIf);

  if (!($Files)) {
    Write-Verbose "No files specified. Finding files...";
    $Files = rg --files -e $Find;
    Write-Verbose "Found $($Files.Length) files.";
  }

  $Files = $Files | %{
    if ($_ | gm FullName) {
      $_.FullName;
    } else {
      $_;
    }
  } | ?{ if (Test-Path $_) { $true; } else { Write-Warning "Path not found $_. Skipping."; } };
  $TempPath = (gi $env:TEMP).FullName;

  $idx = 0;
  $Files | %{
    $TempFile = Join-Path $TempPath ("find-replace-" + (Get-Random) + ".tmp");
    ++$idx;
    $percentComplete = [int]($idx / $Files.Length * 100);
    Write-Verbose "Processing $_ $percentComplete%";
    Write-Progress -Activity "Find and replace" -Status "Processing $_" -PercentComplete $percentComplete;
    rg --passthru -e $Find --replace=$Replace $_ > $TempFile;
    if ($WhatIf) {
      diff (gc $_) (gc $TempFile);
    } else {
      mv $TempFile $_ -fo;
    }
  }

  Write-Progress -Activity "Find and replace" -Complete;
}