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
        $currentDate = $null;

        do {
            $currentDate = (Get-ChildItem $buildLogPath).LastWriteTime;
            Write-Host -NoNewline ".";
            if ($previousDate -ne $currentDate) {
                $previousDate = $currentDate;

                "";
                "---START LOG note---";
                Get-Content $buildLogPath;
                "---END LOG note---";
                "--$($currentDate)--";
            } else {
                Start-Sleep -Seconds 1;
            }
        } while ($true);
    }
}