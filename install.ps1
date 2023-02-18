# winget install --id Microsoft.Powershell --source winget # install latest PowerShell
# winget install git --source winget # install git

$profilePath = (Get-Item ~).FullName;
$paths = @("profile.ps1", "TerminalClickable.format.ps1xml", "oh-my-posh.json");

$paths | ForEach-Object {
    $path = $_;
    $targetPath = (Join-Path $profilePath $path);
    $sourcePath = (Join-Path $PSScriptRoot $path);
    New-Item -Force -ItemType HardLink -Path $targetPath -Value $sourcePath;
}

if (!(gc $profile | ?{ $_ -like ". ~\profile.ps1" })) {
    "`n. ~\profile.ps1" >> $profile;
}