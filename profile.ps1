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
oh-my-posh init pwsh --config (gi ~/oh-my-posh.json).FullName | Invoke-Expression;

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

Update-FormatData -PrependPath ~\TerminalClickable.format.ps1xml;