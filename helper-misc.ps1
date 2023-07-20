
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
