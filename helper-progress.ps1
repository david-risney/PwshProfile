$sw = [Diagnostics.Stopwatch]::StartNew()
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$global:progressIdx = 0;

function IncrementProgress {
  param($Name);
  ++$global:progressIdx;
  Write-Verbose ("Loading profile $Name " + " (" + $swTotal.Elapsed.ToString() + ", " + $sw.Elapsed.ToString() + ")");
  $sw.Restart();

  if ($global:progressIdx -eq $global:maxProgress) {
    Write-Progress -Activity "Loading Profile" -Complete;
  } else {
    $percentComplete = (($global:progressIdx) / ($global:maxProgress) * 100);
    if ($percentComplete -gt 100) {
      Write-Verbose ("You need to update maxProgress to reflect the actual count of IncrementProgress calls in this file.");
      $percentComplete = 100;
    }
    Write-Progress -Activity "Loading Profile" -Status $Name -PercentComplete $percentComplete;
  }
}
