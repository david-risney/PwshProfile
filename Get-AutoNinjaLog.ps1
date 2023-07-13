[CmdletBinding()]
param(
    $Path,
    [switch] $Watch);

# find the most recently run folder under gitRoot\out
$OutPath = (Get-ChildItem -Path "$Path\out" -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName;
Write-Verbose "OutPath: $OutPath";

$buildLogPath = "$OutPath\build.log";
Write-Verbose "BuildLogPath: $buildLogPath";

if (!(Test-Path $buildLogPath)) {
    $thisScriptPath = $MyInvocation.MyCommand.Path;
    "$thisScriptPath (1,1): error: build.log not found in $OutPath";
    exit 1;
} else {
    if (!($Watch)) {
        findstr "error info warning note" "$OutPath\build.log"
    } else {
        Get-Content $OutPath\build.log -Wait;
    }
}