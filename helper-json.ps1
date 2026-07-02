
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
  $tempPath = Join-Path $outDir ([System.IO.Path]::GetRandomFileName());
  try {
    $content | Out-File $tempPath -Encoding $encoding;
    # Move-Item -Force replaces the destination atomically on the same volume.
    Move-Item -LiteralPath $tempPath -Destination $outFilePath -Force;
  } finally {
    if (Test-Path -LiteralPath $tempPath) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue;
    }
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
