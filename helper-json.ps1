
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

function MergeJsonFiles ($inJsonFilePaths, $outJsonFilePath, $encoding = "Utf8") {
  $inJson = ($inJsonFilePaths | ForEach-Object { 
    Get-Content $_ -Raw;
  });
  $outJson = MergeJson $inJson;
  $outJson | Out-File $outJsonFilePath -Encoding $encoding;
}
