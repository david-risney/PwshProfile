# Get root folder of current source repository
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

# Go to root folder of current source repository
function Set-LocationRoot {
    $root = (Get-LocationRoot);
    if ((Get-Location).Path -eq $root) {
        Set-Location ..
        $root = (Get-LocationRoot);
    }
    Set-Location $root;
}

Set-Alias \ Set-LocationRoot

function Get-GitPullRequestUri {
  $repoUri = (git config remote.origin.url);
  if ($repoUri) {
    if ($repoUri.Contains("github.com")) {
      $repoUri = $repoUri.Replace(".git", "");

      $currentBranch = (git rev-parse --abbrev-ref HEAD);
      $uriEncodedCurrentBranch = [uri]::EscapeDataString($currentBranch);

      $repoUri = $repoUri + `
        "/compare/" + $uriEncodedCurrentBranch + "?expand=1";
    } elseif ($repoUri.Contains("azure") -or $repoUri.Contains("visualstudio.com")) {
      $currentBranch = (git rev-parse --abbrev-ref HEAD);
      $uriEncodedCurrentBranch = [uri]::EscapeDataString($currentBranch);

      $targetBranch = (git symbolic-ref refs/remotes/origin/HEAD --short).Replace("origin/", "");
      $uriEncodedTargetBranch = [uri]::EscapeDataString($targetBranch);

      $repoUri = $repoUri + `
        '/pullrequestcreate?' + `
        'sourceRef=' + $uriEncodedCurrentBranch + `
        '&targetRef=' + $uriEncodedTargetBranch;
    }
  }
 
  $repoUri;
}

function Open-PullRequest {
  $uri = Get-AdoPullRequestForBranch -OutputFormat Uri -ErrorAction Ignore;
  if (!($uri)) {
    $uri = Get-GitPullRequestUri;
  }
  Start-Process ($uri);
}

New-Alias -f Create-PullRequest Open-PullRequest;

# Function to get the URI of the current git repo set
# to the specificed path.
function Get-GitUri {
  param($Path = ".");

  $Path = (Get-Item $Path).FullName.Replace("\", "/");

  $repoUri = (git config remote.origin.url);
  if ($repoUri) {
    if ($repoUri.Contains("github.com")) {
      $gitRootPath = (git rev-parse --show-toplevel).ToLower();
      $repoUri = $repoUri.Replace(".git", "");

      $currentPathInGit = $Path.Substring($gitRootPath.Length);

      $currentBranch = (git rev-parse --abbrev-ref HEAD);
      $uriEncodedCurrentBranch = [uri]::EscapeDataString($currentBranch);

      $repoUri = $repoUri + `
        "/tree/" + $uriEncodedCurrentBranch + `
        "/" + $currentPathInGit;
    } elseif ($repoUri.Contains("azure") -or $repoUri.Contains("visualstudio.com")) {
      $gitRootPath = (git rev-parse --show-toplevel).ToLower();
      $currentPathInGit = $Path.ToLower().Replace($gitRootPath, "");
      $uriEncodedCurrentPathInGit = [uri]::EscapeDataString($currentPathInGit);

      $currentBranch = (git rev-parse --abbrev-ref HEAD);
      $uriEncodedCurrentBranch = [uri]::EscapeDataString($currentBranch);

      $repoUri = $repoUri + `
        "?path=" + $uriEncodedCurrentPathInGit + `
        "&version=GB" + $uriEncodedCurrentBranch + `
        "&_a=contents";
    }

  }
 
  $repoUri;
}

function GitRebaseOnto {
  <#
  .SYNOPSIS
  # Git-RebaseOnto.ps1 rebases the current branch onto an official branch.

  .EXAMPLE
  # Use git log -10 to find the branch source commit
  # Git-RebaseOnto.ps1 -BranchTarget main -BranchSource 38743dadac2951a19b397322280783cb4907224f -Verbose
  #>
  [CmdletBinding()]
  param(
      [Parameter(Mandatory=$true)] $BranchTarget,
      $BranchToRebase,
      [switch] $PullBranchToRebase,
      $BranchSource,
      [switch] $PullBranchSource,
      [switch] $WhatIf
      );

  if (!$BranchToRebase) {
      $BranchToRebase = git branch | Where-Object { $_.StartsWith("*") } | ForEach-Object { $_.substring(2) }
  }

  if (!$BranchSource) {
      $BranchSource = (git merge-base $BranchToRebase $BranchTarget);
  }

  Write-Verbose "BranchToRebase: $BranchToRebase";
  Write-Verbose "BranchSource: $BranchSource";
  Write-Verbose "BranchTarget: $BranchTarget";
  Write-Verbose "";

  if ($PullBranchSource) {
      Write-Verbose "Pull $BranchSource";
      if (!$WhatIf) {
          git checkout $BranchSource;
          git pull;
      }
  }

  Write-Verbose "Pull $BranchTarget";
  if (!$WhatIf) {
      git checkout $BranchTarget;
      git pull;
  }

  if ($PullBranchToRebase) {
      Write-Verbose "Pull $BranchToRebase";
      if (!$WhatIf) {
          git checkout $BranchToRebase;
          git pull;
      }
  }

  Write-Verbose "git rebase --onto $BranchTarget $BranchSource $BranchToRebase;";
  if (!$WhatIf) {
      git rebase --onto $BranchTarget $BranchSource $BranchToRebase;
  }

  Write-Verbose "Resulting status. You may need to finish a merge.";
  Write-Verbose 'git status (shows any changes under "Unmerged paths". Open the file and resolve the conflicts)'
  Write-Verbose 'git add <file that was resolved>'
  Write-Verbose 'git status (this will tell you all have been resolved)'
  Write-Verbose 'git rebase --continue (or git rebase --abort to get back to the state before the rebase was started)'
  Write-Warning 'If the branch has previously been pushed to the server, do *not* run git pull, instead run'
  Write-Warning '    git push --force'
}

function GitAddAll {
  <#
  .SYNOPSIS
  # GitAddAll does a git add on all modified or untracked files. Its different from git add * in that it doesn't interact with submodules. It only adds or removes things listed by git status.

  #>
  [CmdletBinding()]
  param();

  $gitStatus = git status -s;
  $gitStatus | ForEach-Object {
    $line = $_;
    $info = $line.Substring(0, 2);
    $path = $line.Substring(3);
    
    switch ($info) {
      " M" { # Modified in working directory
        git add $path;
      }
      "MM" { # Modified in index and working directory
        git add $path;
      }
      "??" { # Untracked
        git add $path;
      }
      " D" { # Deleted
        git rm $path;
      }
      "AD" { # Added to index and deleted
        git rm $path;
      }
      "AM" { # Added to index and modified
        git add $path;
      }
      "RM" { # Removed from index and modified
        git add $path;
      }
      default {
        Write-Error "Unknown info kind $info for $path";
      }
    }
  }
}

function Get-GitChangePaths {
  [CmdletBinding()]
  param(
    $SetPathMatch,
    [switch] $FullPaths,
    [switch] $OnlyGitStatusFiles,
    $BranchCommit);

  Write-Verbose "Rebuilding git change paths cache";
  $gitRoot = (git rev-parse --show-toplevel);
  Write-Verbose ("gitroot: " + $gitRoot);

  if (!$BranchCommit) {
    $BranchCommit = (git merge-base origin/main HEAD);
  }
  Write-Verbose ("Branch commit: " + $BranchCommit);

  $gitStatusFiles = git status -s | ForEach-Object {
    $path = $_.substring(3);
    if (Test-Path $path) {
      (Get-Item $path).FullName;
    }
  };
  Write-Verbose "Found $($gitStatusFiles.Count) git status files";

  if (!$OnlyGitStatusFiles) {
    $gitBranchFiles = git diff --name-only $BranchCommit | ForEach-Object {
      $path = (Join-Path $gitRoot $_);
      if (Test-Path $path) {
        (Get-Item $path).FullName;
      }
    };
    Write-Verbose "Found $($gitBranchFiles.Count) git branch files";
  }

  $gitFiles = @($gitStatusFiles) + @($gitBranchFiles);

  if (!$FullPaths) {
    # Convert to containing folder paths
    $gitFiles = $gitFiles | ForEach-Object {
      (Split-Path $_ -Parent);
    };
  }

  $gitFiles = $gitFiles | Sort-Object -Unique;
  if ($null -ne $SetPathMatch) {
    # Filter to just matching paths
    $gitFiles = $gitFiles | Where-Object { $_ -match $SetPathMatch };
    Write-Verbose "Found $($gitFiles.Count) matching git change paths";

    if ($gitFiles.Count -gt 1) {
      # Reorder array to start with firstMatchIndex and then wrap around.
      # This way if we're currently on a file that matches the set path match we'll go to the next path
      # in the list if we're called the same way again.
      $firstMatchIndex = 0;
      $cwd = (Get-Location).Path;
      while ($firstMatchIndex -lt $gitFiles.Length -and $gitFiles[$firstMatchIndex].ToLower() -ne $cwd.ToLower()) {
        ++$firstMatchIndex;
      }
      # If we're on the last index or no match was found, no need to reorder
      if ($firstMatchIndex -lt $gitFiles.Length - 1) {
        $gitFiles = $gitFiles[($firstMatchIndex + 1)..($gitFiles.Length - 1)] + $gitFiles[0..$firstMatchIndex];
      }
    }

    if ($gitFiles.Count -gt 0) {
      Set-Location $gitFiles[0];
    }
  } else {
    $gitFiles;
  }
}

function gitcd {
  [CmdletBinding()]
  param($SetPathMatch = "");
  Get-GitChangePaths -SetPathMatch $SetPathMatch;
}

function GetAdoAuthTokenForOrigin {
  param([string] $OriginUri);

  az account get-access-token --query accessToken --output tsv # --resource=$OriginUri;
}

function Get-ReviewedBy {
  param([string] $Path);
  git log -- $Path | 
    Select-String "Reviewed-by: (.*)" | 
    Group | Sort Count -Descending | 
    Select Name, Count;
}

function Search-GitCode {
  param([string] $Query,
        [ValidateSet("Rg","Files","FullName","PSObject")] [string] $OutputFormat = "Rg");

  $InnerOutputFormat = $OutputFormat;
  if ($OutputFormat -eq "Rg") { $InnerOutputFormat = "FullName"; }

  $gitServer = git remote get-url origin;
  if ($gitServer -match "https://github.com/([^/]+)/([^/]+)\.git") {
    $results = Search-GitHubCode $Query -OutputFormat $InnerOutputFormat;
  } elseif ($gitServer -eq "https://chromium.googlesource.com/chromium/src.git") {
    $results = Search-GitHubCode $Query -OutputFormat $InnerOutputFormat;
  } else {
    $results = Search-GitAdoCode $Query -OutputFormat $InnerOutputFormat;
  }

  if ($OutputFormat -eq "Rg") {
    $results | ForEach-Object { 
      rg -p -H $Query $_ | Clickify;
      "";
    };
  } else {
    $results;
  }
}

function Search-GitHubCode {
  param([string] $Query,
        [ValidateSet("Files","FullName","PSObject")] [string] $OutputFormat = "Files");

  $gitServer = git remote get-url origin;
  if ($gitServer -match "https://github.com/([^/]+)/([^/]+)\.git") {
    $Organization = $matches[1];
    $Repository = $matches[2];
  } elseif ($gitServer -eq "https://chromium.googlesource.com/chromium/src.git") {
    $Organization = "chromium";
    $Repository = "chromium";
  } else {
    throw "Unknown github server $gitServer";
  }

  $root = Get-LocationRoot;
  $paths = gh search code $query --repo $Organization/$Repository --json path,textMatches | ConvertFrom-Json;

  switch ($OutputFormat) {
    "Files" {
      $paths.path | ForEach-Object { Join-Path $root $_ } | Sort-Object -Uniq | ForEach-Object { Get-Item $_ };
    }

    "FullName" {
      $paths.path | ForEach-Object { Join-Path $root $_ } | Sort-Object -Uniq;
    }

    "PSObject" {
      $paths;
    }
  }
}

function Search-GitAdoCode {
    param(
        [string] $Query,
        [string] $Path,
        [string] $Organization,# = "microsoft",
        [string[]] $ProjectNames,# = @("OS"),
        [string[]] $RepositoryNames,# = @("os"),
        [string[]] $BranchNames = @(),
        [int] $SkipResults = 0,
        [int] $TakeResults = 200,
        [string] $AuthenticationPersonalAccessToken,
        [ValidateSet("Files","FullName","PSObject")] [string] $OutputFormat = "Files",
        [string] $ApiHost = "almsearch.dev.azure.com",
        [string] $ApiName = "_apis/search/codesearchresults?api-version=7.0" # "_apis/search/codesearchresults?api-version=5.0-preview.1"
        );
    
    $root = Get-LocationRoot;
  
    $gitRemote = (git remote -v)[0].Split("`t")[1].Split(" ")[0];
    if ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    } elseif ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/DefaultCollection/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        $AuthenticationPersonalAccessToken = $env:AuthenticationPersonalAccessToken;
    }

    if (!($AuthenticationPersonalAccessToken)) {
      $AuthenticationPersonalAccessToken = GetAdoAuthTokenForOrigin "https://$ApiHost";
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        throw "Must provide valid AuthenticationPersonalAccessToken parameter. See https://www.visualstudio.com/en-us/docs/integrate/get-started/auth/overview";
    }
  
    if (!($BranchNames)) {
      if ($env:SDXROOT) {
        $currentBranch = "official/$(SourceControl.Git.ShellAdapter GetOfficialBranch)"; #(gc (join-path $env:SDXROOT ".git\HEAD")).substring("ref: refs/heads/".length);
        $BranchNames = @($currentBranch);
      }
      else {
        $BranchNames = (git rev-parse --abbrev-ref HEAD);
      }
    }
  
    $BranchNames = @($BranchNames);
    $ProjectNames = @($ProjectNames);
    $RepositoryNames = @($RepositoryNames);
  
    $fullUri = "https://$ApiHost/$Organization/$ProjectNames/$ApiName";
  
    if (!($Path) -and $root) {
        $Path = (Get-Location).Path.Substring($root.length)
    }
  
    if ($Path) {
        $Query += " path:$Path";
    }
  
    # POST params
    $postBody = New-Object PSObject |
        Add-Member searchText $Query -P |
        Add-Member '$top' $TakeResults -P |
        Add-Member '$skip' $SkipResults -P |
    #    Add-Member searchFilters $null -P |
    #    Add-Member sortOptions $null -P |
    #    Add-Member summarizedHitCountsNeeded $false -P |
        Add-Member filters (New-Object PSObject |
            Add-Member 'Project' @($ProjectNames) -P |
            Add-Member 'Repository' @($RepositoryNames) -P |
            Add-Member 'Branch' @($BranchNames) -P
        ) -P | ConvertTo-Json -Depth 10;
  
    $user = "";
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $user,$AuthenticationPersonalAccessToken)));
  
    Write-Verbose $fullUri
    Write-Verbose $postBody
  
    $result = (Invoke-RestMethod -Uri $fullUri -Method Post -ContentType "application/json" -Body $postBody -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});
  
    Write-Verbose ("Results " + $SkipResults + " through " + ([int]$SkipResults + $result.Results.Count) + " of " + $result.count + " total.");
  
    if ($result.results.count -gt 0) {
        switch ($OutputFormat) {
            "Files" {
                $files = $result.results.path;
                if ($root) {
                    $files | ForEach-Object { Join-Path $root $_ } | Sort-Object -Uniq | ForEach-Object { Get-Item $_ };
                } else {
                    $files;
                }
            }
  
            "FullName" {
                $files = $result.results.path;
                if ($root) {
                    $files | ForEach-Object { Join-Path $root $_ } | Sort-Object -Uniq;
                } else {
                    $files;
                }
            }
  
            "PSObject" {
                $result;
            }
        }
    }
}

function Watch-AdoPullRequestIssues {
    param(
        [string] $Path = ".",
        [Alias("prid")] [string] $PullRequestId = $null,
        [string] $Organization = $null,# = "microsoft",
        [string[]] $ProjectNames = $null,# = @("OS"),
        [string[]] $RepositoryNames = $null,# = @("os"),
        [string[]] $BranchNames = @(),
        [string] $AuthenticationPersonalAccessToken = $null,
        [ValidateSet("Text", "ErrorText", "PSObject")] [string] $OutputFormat = "Text",
        [string] $ApiHost = "dev.azure.com",
        [string] $ApiName = "_apis/git/repositories",
        [string] $BuildErrors = "exclude",
        [int32] $WatchDelayInSeconds = 1 * 60
        );

    do {
      "---START LOG note---";
      ("Getting ADO PR Issues $PullRequestId at " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"));
      "";

      Get-AdoPullRequestIssues `
        -Path $Path `
        -PullRequestId $PullRequestId `
        -Organization $Organization `
        -ProjectNames $ProjectNames `
        -RepositoryNames $RepositoryNames `
        -BranchNames $BranchNames `
        -AuthenticationPersonalAccessToken $AuthenticationPersonalAccessToken `
        -OutputFormat $OutputFormat `
        -ApiHost $ApiHost `
        -ApiName $ApiName `
        -BuildErrors $BuildErrors;

      "---END LOG note---";
      "";
      Start-Sleep $WatchDelayInSeconds;
    } while ($WatchDelayInSeconds -gt 0);
    
}

function Get-AdoPullRequestIssues {
    param(
        [string] $Path = ".",
        [Alias("prid")] [string] $PullRequestId,
        [string] $Organization,# = "microsoft",
        [string[]] $ProjectNames,# = @("OS"),
        [string[]] $RepositoryNames,# = @("os"),
        [string[]] $BranchNames = @(),
        [string] $AuthenticationPersonalAccessToken,
        [ValidateSet("Text", "ErrorText", "PSObject")] [string] $OutputFormat = "Text",
        [string] $ApiHost = "dev.azure.com",
        [string] $ApiName = "_apis/git/repositories",
        [string] $BuildErrors = "exclude"
        );
    
    pushd $Path;

    $root = Get-LocationRoot;
  
    $gitRemote = (git remote -v)[0].Split("`t")[1].Split(" ")[0];
    if ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    } elseif ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/DefaultCollection/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        $AuthenticationPersonalAccessToken = $env:AuthenticationPersonalAccessToken;
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
      $AuthenticationPersonalAccessToken = GetAdoAuthTokenForOrigin "https://$ApiHost";
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        throw "Must provide valid AuthenticationPersonalAccessToken parameter. See https://www.visualstudio.com/en-us/docs/integrate/get-started/auth/overview";
    }
  
    if (!($BranchNames)) {
      $BranchNames = (git rev-parse --abbrev-ref HEAD);
    }

    if (!$PullRequestId) {
        $PullRequestId = Get-AdoPullRequestForBranch;
    }
  
    $BranchNames = @($BranchNames);
    $ProjectNames = @($ProjectNames);
    $RepositoryNames = @($RepositoryNames);
    $repoName = $RepositoryNames[0];
  
    $fullUri = "https://$ApiHost/$Organization/$ProjectNames/$ApiName/$repoName/pullRequests/$PullRequestId/threads?api-version=7.1-preview.1";
  
    $user = "";
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $user,$AuthenticationPersonalAccessToken)));
  
    Write-Verbose $fullUri

    $results = @();
    
    $result = (Invoke-RestMethod -Uri $fullUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});
    $result.value | Where-Object { 
        $_.status -eq "active" -and
        $_.threadContext -and
        $_.threadContext.filePath
    } | ForEach-Object {
        $file = $_.threadContext.filePath;
        $line = 1;
        $column = 1;
        if ($_.threadContext.rightFileStart) {
            if ($_.threadContext.rightFileStart.line) {
              $line = $_.threadContext.rightFileStart.line;
            }
            if ($_.threadContext.rightFileStart.offset) {
              $column = $_.threadContext.rightFileStart.offset;
            }
        }

        $text = $_.comments[0].content;

        $results += @(New-Object PSObject @{
          "file"=$file;
          "line"=$line;
          "column"=$column;
          "text"=$text;
        });
    }

    if ($BuildErrors -eq "include") {
      $buildIds = @($result.value | ForEach-Object {
        $_.comments | ?{ $_.content } | %{ 
          $_.content.split("`n") | ?{ $_.Contains("Failed"); } | %{
              if ($_ -match "buildId=([0-9]+)") {
                $matches[1];
              }
            }
          }
        }) | ?{ $_ };
      $buildIds | %{
        $build = (Get-AdoBuild -BuildId $_);
        $timelineUri = $build._links.timeline.href;
        $timelineResult = (Invoke-RestMethod -Uri $timelineUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});
        $timelineResult.records | ?{ $_.issues } | %{
          $logUri = $_.log.url;
          $logResult = (Invoke-RestMethod -Uri $logUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});
          $logResult.Split("`n") | ?{ $_.Contains(" error:") } | %{
            $spaceIdx = $_.IndexOf(" ");
            $line = $_.Substring($spaceIdx + 1);
            if ($line -match "([^:]+):([0-9]+):([0-9]+):[^:]+: (.*)") {
              $file = $matches[1];
              $line = $matches[2];
              $column = $matches[3];
              $text = $matches[4];

              if ($file.StartsWith("../../")) {
                $file = $file.Substring("../../".Length);
              }

              $results += @(New-Object PSObject @{
                "file"=$file;
                "line"=$line;
                "column"=$column;
                "text"=$text;
              });
            }
          }
        }
      };
    }

    switch ($OutputFormat) {
        "ErrorText" {
            $results | ForEach-Object {
                Write-Error ("$($_.file)($($_.line),$($_.column)): error: $($_.text)");
            }
        }

        "Text" {
            $results | ForEach-Object {
                $path = "../../" + $_.file.TrimStart("/");
                $text = @($_.text) -join " ";
                $text = $text.Replace("`r", " ").Replace("`n", " ");
                ("$path($($_.line),$($_.column)): error: $text");
            }
        }

        "PSObject" {
            $result;
        }
    } 

    popd;
}

function Get-AdoBuild {
  [CmdletBinding()]
    param(
        [string] $Path = ".",
        [string] $BuildId,
        [string] $Organization,# = "microsoft",
        [string[]] $ProjectNames,# = @("OS"),
        [string[]] $RepositoryNames,# = @("os"),
        [string[]] $BranchNames = @(),
        [string] $AuthenticationPersonalAccessToken,
        [ValidateSet("Text", "ErrorText", "PSObject")] [string] $OutputFormat = "Text",
        [string] $ApiHost = "dev.azure.com",
        [string] $ApiName = "_apis/build/builds"
        );
    
    pushd $Path;

    $root = Get-LocationRoot;
  
    $gitRemote = (git remote -v)[0].Split("`t")[1].Split(" ")[0];
    if ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    } elseif ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/DefaultCollection/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        $AuthenticationPersonalAccessToken = $env:AuthenticationPersonalAccessToken;
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
      $AuthenticationPersonalAccessToken = GetAdoAuthTokenForOrigin "https://$ApiHost";
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        throw "Must provide valid AuthenticationPersonalAccessToken parameter. See https://www.visualstudio.com/en-us/docs/integrate/get-started/auth/overview";
    }
  
    if (!($BranchNames)) {
      $BranchNames = (git rev-parse --abbrev-ref HEAD);
    }

    if (!$PullRequestId) {
        $PullRequestId = Get-AdoPullRequestForBranch;
    }
  
    $BranchNames = @($BranchNames);
    $ProjectNames = @($ProjectNames);
    $RepositoryNames = @($RepositoryNames);
    $repoName = $RepositoryNames[0];
  
    # $fullUri = "https://$ApiHost/$Organization/$ProjectNames/$ApiName/$repoName/pullRequests/$PullRequestId/threads?api-version=7.1-preview.1";
    $fullUri = ("https://$ApiHost/$Organization/$ProjectNames/$ApiName/$BuildId" + "?api-version=7.1-preview.1");
  
    $user = "";
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $user,$AuthenticationPersonalAccessToken)));
  
    Write-Verbose $fullUri

    $result = (Invoke-RestMethod -Uri $fullUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});
    $fullUri = $result.url;
    $result = (Invoke-RestMethod -Uri $fullUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});

    $result;

    popd;
}

function Get-AdoBuildLogs {
  [CmdletBinding()]
    param(
        [string] $Path = ".",
        [string] $BuildId,
        [string] $LogId,
        [string] $Organization,# = "microsoft",
        [string[]] $ProjectNames,# = @("OS"),
        [string[]] $RepositoryNames,# = @("os"),
        [string[]] $BranchNames = @(),
        [string] $AuthenticationPersonalAccessToken,
        [ValidateSet("Text", "ErrorText", "PSObject")] [string] $OutputFormat = "Text",
        [string] $ApiHost = "dev.azure.com",
        [string] $ApiName = "_apis/build/builds"
        );
    
    pushd $Path;

    $root = Get-LocationRoot;
  
    $gitRemote = (git remote -v)[0].Split("`t")[1].Split(" ")[0];
    if ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    } elseif ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/DefaultCollection/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        $AuthenticationPersonalAccessToken = $env:AuthenticationPersonalAccessToken;
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
      $AuthenticationPersonalAccessToken = GetAdoAuthTokenForOrigin "https://$ApiHost";
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        throw "Must provide valid AuthenticationPersonalAccessToken parameter. See https://www.visualstudio.com/en-us/docs/integrate/get-started/auth/overview";
    }
  
    if (!($BranchNames)) {
      $BranchNames = (git rev-parse --abbrev-ref HEAD);
    }

    if (!$PullRequestId) {
        $PullRequestId = Get-AdoPullRequestForBranch;
    }
  
    $BranchNames = @($BranchNames);
    $ProjectNames = @($ProjectNames);
    $RepositoryNames = @($RepositoryNames);
    $repoName = $RepositoryNames[0];
  
    # $fullUri = "https://$ApiHost/$Organization/$ProjectNames/$ApiName/$repoName/pullRequests/$PullRequestId/threads?api-version=7.1-preview.1";
    $fullUri = ("https://$ApiHost/$Organization/$ProjectNames/$ApiName/$BuildId/logs/$LogId" + "?api-version=7.1-preview.2");
  
    $user = "";
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $user,$AuthenticationPersonalAccessToken)));
  
    Write-Verbose $fullUri

    $result = (Invoke-RestMethod -Uri $fullUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});
    $result;

    popd;
}

function Get-AdoPullRequestForBranch {
  [CmdletBinding()]
    param(
        [string] $Organization,# = "microsoft",
        [string[]] $ProjectNames,# = @("OS"),
        [string[]] $RepositoryNames,# = @("os"),
        [string[]] $BranchNames = @(),
        [string] $AuthenticationPersonalAccessToken,
        [ValidateSet("Id", "Uri", "PSObject")] [string] $OutputFormat = "Id",
        [string] $ApiHost = "dev.azure.com",
        [string] $ApiName = "_apis/git/repositories"
        );
    
    $root = Get-LocationRoot;
  
    $gitRemote = (git remote -v)[0].Split("`t")[1].Split(" ")[0];
    if ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    } elseif ($gitRemote -match "https\:\/\/([^\.]+)\.visualstudio.com\/DefaultCollection/([^/]+)\/_git\/(.*)") {
      $Organization = $matches[1].ToLower();
      $ProjectNames = $matches[2];
      $RepositoryNames = $matches[3];
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        $AuthenticationPersonalAccessToken = $env:AuthenticationPersonalAccessToken;
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
      $AuthenticationPersonalAccessToken = GetAdoAuthTokenForOrigin "https://$ApiHost";
    }
  
    if (!($AuthenticationPersonalAccessToken)) {
        throw "Must provide valid AuthenticationPersonalAccessToken parameter. See https://www.visualstudio.com/en-us/docs/integrate/get-started/auth/overview";
    }
  
    if (!($BranchNames)) {
      if ($env:SDXROOT) {
        $currentBranch = "official/$(SourceControl.Git.ShellAdapter GetOfficialBranch)"; #(gc (join-path $env:SDXROOT ".git\HEAD")).substring("ref: refs/heads/".length);
        $BranchNames = @($currentBranch);
      }
      else {
        $BranchNames = (git rev-parse --abbrev-ref HEAD);
      }
    }
  
    $BranchNames = @($BranchNames);
    $ProjectNames = @($ProjectNames);
    $RepositoryNames = @($RepositoryNames);
    $repoName = $RepositoryNames[0];
    $branchName = $BranchNames[0];
  
    $fullUri = "https://$ApiHost/$Organization/$ProjectNames/$ApiName/$repoName/pullrequests?searchCriteria.sourceRefName=refs/heads/$branchName&api-version=7.1-preview.1";
  
    $user = "";
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $user,$AuthenticationPersonalAccessToken)));
  
    Write-Verbose $fullUri

    $result = (Invoke-RestMethod -Uri $fullUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});
    if ($result) {
      switch ($OutputFormat) {
          "Id" {
              $result.value | ForEach-Object {
                  $_.pullRequestId;
              }
          }

          "Uri" {
              $result.value | ForEach-Object {
                  $repoUri = (git config remote.origin.url);
                  ($repoUri + "/pullrequest/" + $_.pullRequestId);
              }
          }

          "PSObject" {
              $result;
          }
      }
    }
}

function Get-NotesPath {
  param(
    [string] $RootPath = $env:NOTESPATH,
    [string] $NotesFolder = (git rev-parse --abbrev-ref HEAD),
    [string] $NotesFile = "notes.md"
  );

  if (!$RootPath) {
    $RootPath = (Get-Item ~).FullName;
  }

  if (!$NotesFolder) {
    $NotesFolder = "notes";
  }

  Join-Path $RootPath $NotesFolder $NotesFile;
}

function Open-Notes {
  $notesPath = Get-NotesPath;
  if (!(Test-Path $notesPath)) {
    touch $notesPath;
  }
  . (Get-NotesPath);
}

function Get-Notes {
  $notesPath = Get-NotesPath;
  if (Test-Path $notesPath) {
    glow $notesPath;
  }
}
New-Alias -f notes Get-Notes;
