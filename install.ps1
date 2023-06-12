# winget install --id Microsoft.Powershell --source winget # install latest PowerShell
# winget install git --source winget # install git
# winget install Microsoft.VisualStudioCode # install VSCode
# winget install Microsoft.VisualStudio.2022.Enterprise
# winget install Microsoft.PowerToys # install PowerToys

$userProfilePath = (Join-Path $PSScriptRoot "profile.ps1");

if (!(gc $profile | ?{ $_ -like $userProfilePath })) {
    "`n. `"$userProfilePath`"" >> $profile;
}
