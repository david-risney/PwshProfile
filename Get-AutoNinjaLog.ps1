[CmdletBinding()]
param(
    $Path,
    [switch] $Watch);

# find the most recently run folder under gitRoot\out
$buildLogPath = (Get-ChildItem @(
        "$Path\out\*\siso_output",
        "$Path\out\*\build.log") -File -ErrorAction Ignore | 
        Sort-Object LastWriteTime -Descending | 
        Select-Object -First 1
    ).FullName;

Write-Verbose "BuildLogPath: $buildLogPath";

if (!(Test-Path $buildLogPath)) {
    $thisScriptPath = $MyInvocation.MyCommand.Path;
    "$thisScriptPath (1,1): error: $buildLogPath not found";
    exit 1;
} else {
    if (!($Watch)) {
        findstr "error info warning note" "$buildLogPath"
    } else {
        $previousDate = $null;
        $currentDate = (Get-ChildItem $buildLogPath).LastWriteTime;
        do {
            if ($previousDate -ne $currentDate) {
                $previousDate = $currentDate;
                $currentDate = (Get-ChildItem $buildLogPath).LastWriteTime;

                "---START LOG note---";
                Get-Content $buildLogPath;
                "---END LOG note---";
            } else {
                Start-Sleep -Seconds 1;
            }
        } while ($true);
    }
}