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
  param($ModuleName);

  Import-Module $ModuleName -ErrorAction Ignore;

  if (!(Get-Module $ModuleName)) {
    Write-Output "Install $ModuleName";
    if ((Get-Command install-module)[0].Parameters["AllowPrerelease"]) {
      Install-Module -Name $ModuleName -Force -Repository PSGallery -AllowPrerelease -Scope CurrentUser;
    } else {
      Install-Module -Name $ModuleName -Force -Repository PSGallery -Scope CurrentUser;
    }
    Import-Module $ModuleName;
  } else {
    [void](Start-Job -ScriptBlock { Update-Module $ModuleName -Scope CurrentUser; });
  }
}

function UpdateOrInstallWinget {
  param($ModuleName);

  if (!(Get-Command $ModuleName -ErrorAction Ignore)) {
    winget install $ModuleName;
  } else {
    [void](Start-Job -ScriptBlock { winget upgrade $ModuleName; });
  }
}

$progressIdx = 0;
$maxProgress = 10;
function IncrementProgress {
  param($Name);
  ++$progressIdx;
  Write-Progress -Activity "Loading Profile" -Status $Name -PercentComplete (($progressIdx * 100) / ($maxProgress));
}

Set-PSRepository PSGallery -InstallationPolicy Trusted;

IncrementProgress "PowerShellGet";
UpdateOrInstallModule PowerShellGet;
IncrementProgress "PSReadLine";
UpdateOrInstallModule PSReadLine; # https://github.com/PowerShell/PSReadLine
IncrementProgress "Terminal-Icon";
UpdateOrInstallModule Terminal-Icons; # https://www.hanselman.com/blog/take-your-windows-terminal-and-powershell-to-the-next-level-with-terminal-icons
IncrementProgress "cd-extras";
UpdateOrInstallModule cd-extras; # https://github.com/nickcox/cd-extras
IncrementProgress "BurntToast";
UpdateOrInstallModule BurntToast; # https://github.com/Windos/BurntToast
IncrementProgress "oh-my-posh";
UpdateOrInstallWinget oh-my-posh; # https://ohmyposh.dev/docs/pwsh/

# IncrementProgress "Posh-Git";
# UpdateOrInstallModule Posh-Git; # https://github.com/dahlbyk/posh-git

# https://github.com/microsoft/cascadia-code/releases
if (!(Get-ChildItem C:\windows\fonts\cascadia*)) {
  Write-Error "Install the Cascadia Code font https://github.com/microsoft/cascadia-code/releases"
}

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