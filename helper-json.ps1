
function MergeJson ($jsons) {
    $settings = New-Object -TypeName Newtonsoft.Json.Linq.JsonMergeSettings
    $settings.MergeArrayHandling = [Newtonsoft.Json.Linq.MergeArrayHandling]::Replace;
    # Use newtonsoft to parse json into object
    $resultObject = $null;
    $jsons | ForEach-Object {
      $jsonObject = [Newtonsoft.Json.JsonConvert]::DeserializeObject($_);

      if (!$resultObject) {
        $resultObject = $jsonObject;
      } else {
        $resultObject.Merge($jsonObject, $settings);
      }
    } 

    $resultObject.ToString();
}

# Write text to a file by first writing to a temp file in the same directory and
# then atomically moving it into place. This avoids leaving a truncated/partial
# destination file if the write is interrupted or if two processes race to update
# the same file (which can, for example, wipe Windows Terminal's profiles.list and
# reset profiles to defaults).
function Out-FileAtomic ($content, $outFilePath, $encoding = "Utf8") {
  $outDir = Split-Path -Parent $outFilePath;
  if (!$outDir) { $outDir = "."; }
  $resolvedDir = (Resolve-Path -LiteralPath $outDir).ProviderPath;
  $destFull = Join-Path $resolvedDir (Split-Path -Leaf $outFilePath);

  # Serialize writers across processes with a named mutex keyed on the destination
  # path, so concurrent updates (e.g. several psmux hooks firing at once, or a hook
  # racing the profile.ps1 startup pass) can't collide while replacing the file.
  # Mutex names can't contain '\', so use a hash of the (case-insensitive) path.
  $sha1 = [System.Security.Cryptography.SHA1]::Create();
  try {
    $hash = [BitConverter]::ToString($sha1.ComputeHash([Text.Encoding]::UTF8.GetBytes($destFull.ToLowerInvariant()))).Replace('-', '');
  } finally { $sha1.Dispose(); }
  $mutex = New-Object System.Threading.Mutex($false, "Global\PwshProfile-OutFileAtomic-$hash");
  $held = $false;
  try {
    try { $held = $mutex.WaitOne(10000); } catch [System.Threading.AbandonedMutexException] { $held = $true; }

    $tempPath = Join-Path $resolvedDir ([System.IO.Path]::GetRandomFileName());
    try {
      $content | Out-File $tempPath -Encoding $encoding;
      # [IO.File]::Move(src,dst,$true) maps to Win32 MoveFileEx with
      # MOVEFILE_REPLACE_EXISTING, overwriting atomically on the same volume
      # (unlike Move-Item -Force, which can fail with "Cannot create a file when
      # that file already exists"). The mutex prevents contention between our own
      # writers; the retry rides out transient locks held by *external* processes
      # (Windows Terminal watching settings.json, Defender, the search indexer),
      # which surface as IOException / UnauthorizedAccessException.
      $attempt = 0;
      $maxAttempts = 8;
      while ($true) {
        try {
          [System.IO.File]::Move($tempPath, $destFull, $true);
          break;
        } catch {
          # A .NET method failure surfaces as a MethodInvocationException whose
          # real cause is the InnerException, so unwrap before deciding to retry.
          $ex = $_.Exception;
          while ($ex.InnerException) { $ex = $ex.InnerException; }
          $transient = ($ex -is [System.IO.IOException]) -or ($ex -is [System.UnauthorizedAccessException]);
          if (!$transient -or ++$attempt -ge $maxAttempts) { throw; }
          Start-Sleep -Milliseconds ([Math]::Min(250, 40 * $attempt));
        }
      }
    } finally {
      if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue;
      }
    }
  } finally {
    if ($held) { $mutex.ReleaseMutex(); }
    $mutex.Dispose();
  }
}

function MergeJsonFilesAndStrings ($inJsonFilePaths, $inJsonStrings, $outJsonFilePath, $encoding = "Utf8") {
  $inJson = @($inJsonFilePaths | ForEach-Object { 
    Get-Content $_ -Raw;
  }) + @($inJsonStrings);
  $outJson = MergeJson $inJson;
  Out-FileAtomic $outJson $outJsonFilePath $encoding;
}

function MergeJsonFiles ($inJsonFilePaths, $outJsonFilePath, $encoding = "Utf8") {
  MergeJsonFilesAndStrings @($inJsonFilePaths) @() $outJsonFilePath $encoding;
}
