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

function Get-GitPathPullRequestStatus {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
    [Alias("FullName")]
    [string[]] $Path
  );

  begin {
    $resolvedPaths = [System.Collections.Generic.List[string]]::new();
  }

  process {
    foreach ($pathPattern in $Path) {
      $resolvedMatches = @(Resolve-Path -Path $pathPattern -ErrorAction SilentlyContinue);
      if ($resolvedMatches.Count -eq 0) {
        Write-Error "Path pattern did not match anything: $pathPattern";
        continue;
      }

      foreach ($match in $resolvedMatches) {
        if (!(Test-Path -LiteralPath $match.ProviderPath -PathType Container)) {
          Write-Error "Path is not a directory: $($match.ProviderPath)";
          continue;
        }

        $resolvedPaths.Add($match.ProviderPath);
      }
    }
  }

  end {
    $seenGitRoots = [System.Collections.Generic.HashSet[string]]::new(
      [System.StringComparer]::OrdinalIgnoreCase);

    foreach ($resolvedPath in $resolvedPaths) {
      $gitRootOutput = @(& git -C $resolvedPath rev-parse --show-toplevel 2>&1);
      if ($LASTEXITCODE -ne 0) {
        Write-Error "Path is not in a git repository: $resolvedPath";
        continue;
      }

      $gitRoot = (Get-Item -LiteralPath ($gitRootOutput | Select-Object -Last 1).ToString()).FullName;
      if (!$seenGitRoots.Add($gitRoot)) {
        continue;
      }

      $branchOutput = @(& git -C $gitRoot rev-parse --abbrev-ref HEAD 2>&1);
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to get the branch for '$gitRoot': $($branchOutput -join [Environment]::NewLine)";
      }
      $branch = ($branchOutput | Select-Object -Last 1).ToString();

      $remoteOutput = @(& git -C $gitRoot remote get-url origin 2>&1);
      if ($LASTEXITCODE -ne 0) {
        Write-Verbose "Repository '$gitRoot' has no origin remote.";
        $remote = $null;
      } else {
        $remote = ($remoteOutput | Select-Object -Last 1).ToString();
      }

      $pullRequestUri = $null;
      $pullRequestNumber = $null;
      $pullRequestStatus = $null;
      $changeLabel = "PR";
      $shouldLookupPullRequest = $branch -notin @("main", "master");

      if ($shouldLookupPullRequest -and $remote -match "(?i)github\.com[/:]") {
        if (!(Get-Command gh -ErrorAction Ignore)) {
          throw "GitHub CLI ('gh') is required to get pull request status for '$gitRoot'.";
        }

        Push-Location $gitRoot;
        try {
          $ghOutput = @(gh pr list --head $branch --state all --limit 1 --json number,url,state 2>&1);
          if ($LASTEXITCODE -ne 0) {
            $ghError = $ghOutput -join [Environment]::NewLine;
            if ($ghError -match "(?i)Could not resolve to a Repository") {
              Write-Warning "GitHub repository for '$gitRoot' is unavailable; skipping pull request lookup.";
            } else {
              throw "Failed to get the GitHub pull request for '$gitRoot': $ghError";
            }
          } else {
            $githubPullRequests = @($ghOutput | ConvertFrom-Json);
            if ($githubPullRequests.Count -gt 0) {
              $pullRequestUri = $githubPullRequests[0].url;
              $pullRequestNumber = $githubPullRequests[0].number;
              $pullRequestStatus = $githubPullRequests[0].state;
            }
          }
        } finally {
          Pop-Location;
        }
      } elseif ($shouldLookupPullRequest -and $remote -match "(?i)chromium\.googlesource\.com[/:]chromium/src") {
        $gerritChange = Get-GerritChangeForBranch -Path $gitRoot -BranchName $branch;
        if ($gerritChange) {
          $pullRequestUri = $gerritChange.Uri;
          $pullRequestNumber = $gerritChange.Number;
          $pullRequestStatus = $gerritChange.Status;
          $changeLabel = "CL";
        }
      } elseif ($shouldLookupPullRequest -and $remote -match "(?i)(dev\.azure\.com|visualstudio\.com)") {
        Push-Location $gitRoot;
        try {
          $adoResult = Get-AdoPullRequestForBranch -BranchNames @($branch) -OutputFormat PSObject;
          $adoPullRequest = $adoResult.value |
            Sort-Object -Property creationDate -Descending |
            Select-Object -First 1;

          if ($adoPullRequest) {
            $pullRequestUri = "$remote/pullrequest/$($adoPullRequest.pullRequestId)";
            $pullRequestNumber = $adoPullRequest.pullRequestId;
            $pullRequestStatus = $adoPullRequest.status;
          }
        } finally {
          Pop-Location;
        }
      }

      [PSCustomObject] @{
        Path = $gitRoot;
        Branch = $branch;
        PR = if ($pullRequestNumber) { "$changeLabel#$pullRequestNumber" } else { $null };
        Status = $pullRequestStatus;
        PRUri = $pullRequestUri;
      };
    }
  }
}

function Open-PullRequest {
  $uri = Get-AdoPullRequestForBranch -OutputFormat Uri -ErrorAction Ignore;
  if (!($uri)) {
    $uri = Get-GerritPullRequestUri -ErrorAction Ignore;
  }
  if (!($uri)) {
    $uri = Get-GitPullRequestUri;
  }
  Start-Process ($uri);
}

function Get-GerritPullRequestUri {
  $change = Get-GerritChangeForBranch -SkipStatus;
  if ($change) {
    $change.Uri;
  }
}

function Get-DepotToolsPath {
  [CmdletBinding()]
  param(
    [string] $RepositoryPath = "."
  );

  $candidates = @();
  if ($env:DEPOT_TOOLS) {
    $candidates += $env:DEPOT_TOOLS;
  }
  $candidates += Join-Path (Split-Path (Get-Item $RepositoryPath).FullName -Parent) "depot_tools";

  $gitClCommand = Get-Command git-cl -ErrorAction Ignore;
  if ($gitClCommand) {
    $candidates += Split-Path $gitClCommand.Source -Parent;
  }

  $candidates |
    Where-Object { $_ } |
    ForEach-Object { (Get-Item $_ -ErrorAction Ignore).FullName } |
    Where-Object { $_ -and (Test-Path (Join-Path $_ "git-cl") -PathType Leaf) } |
    Select-Object -First 1;
}

function Get-GerritChangeForBranch {
  [CmdletBinding()]
  param(
    [string] $Path = ".",
    [string] $BranchName,
    [switch] $SkipStatus
  );

  if (!$BranchName) {
    $BranchName = git -C $Path rev-parse --abbrev-ref HEAD;
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to get the branch for '$Path'.";
    }
  }

  $issue = git -C $Path config --get "branch.$BranchName.gerritissue";
  if ($LASTEXITCODE -ne 0 -or !$issue) {
    return;
  }

  $server = git -C $Path config --get "branch.$BranchName.gerritserver";
  if ($LASTEXITCODE -ne 0 -or !$server) {
    $remote = git -C $Path remote get-url origin;
    if ($remote -match "(?i)chromium\.googlesource\.com") {
      $server = "https://chromium-review.googlesource.com";
    } else {
      throw "No Gerrit server is configured for branch '$BranchName' in '$Path'.";
    }
  }
  $server = $server.TrimEnd("/");

  $status = $null;
  if (!$SkipStatus) {
    $depotToolsPath = Get-DepotToolsPath -RepositoryPath $Path;
    if ($depotToolsPath) {
      $originalPath = $env:PATH;
      try {
        $env:PATH = "$depotToolsPath;$originalPath";
        $statusOutput = @(& git -C $Path cl status --field status 2>&1);
        if ($LASTEXITCODE -ne 0) {
          Write-Warning "Failed to get Gerrit status for CL $issue in '$Path': $($statusOutput -join [Environment]::NewLine)";
        } elseif ($statusOutput.Count -gt 0) {
          $status = ($statusOutput | Select-Object -Last 1).ToString().Trim();
        }
      } finally {
        $env:PATH = $originalPath;
      }
    } else {
      Write-Warning "depot_tools was not found for '$Path'; returning CL $issue without status.";
    }
  }

  [PSCustomObject] @{
    Number = [int]$issue;
    Status = $status;
    Uri = "$server/$issue";
  };
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
    } else {
      $repoUri = $null;
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

function Get-AdoRepositoryInfo {
  [CmdletBinding()]
  param(
    [string] $Remote = (git remote get-url origin)
  );

  if ($Remote -match "^https?://(?:[^@/]+@)?dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/?#]+)") {
    $organization = $matches[1];
    $project = $matches[2];
    $repository = $matches[3];
  } elseif ($Remote -match "^https?://([^.]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git/([^/?#]+)") {
    $organization = $matches[1];
    $project = $matches[2];
    $repository = $matches[3];
  } elseif ($Remote -match "^(?:[^@]+@)?ssh\.dev\.azure\.com:v3/([^/]+)/([^/]+)/(.+)$") {
    $organization = $matches[1];
    $project = $matches[2];
    $repository = $matches[3];
  } else {
    throw "Remote is not an Azure DevOps repository: $Remote";
  }

  [PSCustomObject] @{
    Organization = [uri]::UnescapeDataString($organization);
    OrganizationUri = "https://dev.azure.com/$([uri]::UnescapeDataString($organization))";
    Project = [uri]::UnescapeDataString($project);
    Repository = [uri]::UnescapeDataString($repository);
    Remote = $Remote.TrimEnd("/");
  };
}

function Invoke-AzCli {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string[]] $Arguments,
    [ValidateSet("Json", "Text")]
    [string] $OutputFormat = "Json"
  );

  if (!(Get-Command az -ErrorAction Ignore)) {
    throw "Azure CLI ('az') is required.";
  }

  $azOutputFormat = if ($OutputFormat -eq "Json") { "json" } else { "tsv" };
  $output = @(& az @Arguments --output $azOutputFormat --only-show-errors 2>&1);
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI command failed: az $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)";
  }

  $outputText = $output -join [Environment]::NewLine;
  if ($OutputFormat -eq "Json") {
    if ($outputText) {
      $outputText | ConvertFrom-Json;
    }
  } else {
    $outputText;
  }
}

function Get-ReviewedBy {
  param([string] $Path);
  Write-Progress -Activity "Get-ReviewedBy" -Status "Getting owners" -PercentComplete 1;

  # git cl owner --show-all output looks like the following:
  # Owners for third_party/blink/renderer/core/loader/document_loader.cc:
  #  - name@domain.org
  #  - name2@domain2.org

  # Ensure path is in the form git expects which is using forward slashes
  # and is relative to the root of the git repository.
  # eg C:\cr\src\content\renderer\a\b.cc -> content/renderer/a/b.cc
  $Path = (Get-Item $Path).FullName.Replace("\", "/");
  $gitRoot = (git rev-parse --show-toplevel).ToLower();
  if ($Path.ToLower().StartsWith($gitRoot.ToLower())) {
    $Path = $Path.Substring($gitRoot.Length).TrimStart("/");
  }

  $ownersText = git cl owner --show-all --batch $Path 2>&1;
  $owners = @();
  Write-Progress -Activity "Get-ReviewedBy" -Status "Processing owners" -PercentComplete 20;
  if (!($ownersText -match "is not a git command")) {
    $ownersText | ForEach-Object {
      if (!($_ -match "Owners for (.*):")) {
        $owner = $_.TrimStart("- ");
        $owners += $owner;
      }
    };
  } else {
    $ownersText = git ms owners $Path 2>&1;
    if (!($ownersText -match "is not a git command")) {
      $ownersText[1].Trim().Replace("Owners: ", "").Split("; ") | ForEach-Object {
        $owner = $_.Split(":")[0].Trim();
        $owners += $owner;
      };
    }
  }

  Write-Progress -Activity "Get-ReviewedBy" -Status "Getting history" -PercentComplete 40;
  $gitLog = git log -- $Path;

  Write-Progress -Activity "Get-ReviewedBy" -Status "Processing history" -PercentComplete 60;
  $gitLogProcessed = $gitLog | 
    Select-String "Reviewed-by: (.*)" | 
    Group-Object | 
    Select-Object Name, Count;

  Write-Progress -Activity "Get-ReviewedBy" -Status "Correlating history and owners" -PercentComplete 80;
  $result = $gitLogProcessed | 
    Where-Object { !($_.Name.StartsWith(">")) } |
    ForEach-Object { 
      # Parse email out of name which looks like 'Reviewed-by: Name Othername <nothername@domain.org> '
      $fullName = "";
      $email = "";

      if ($_.Name -match "Reviewed-by: ([^<]+) <([^>]+)>") {
        $fullName = $matches[1].Trim();
        $email = $matches[2].Trim();
      }

      $isOwner = $false;
      if ($owners) {
        $isOwner = ($owners | Where-Object { $_ -eq $email }).Count -gt 0;
      }

      [pscustomobject]@{
        Name = $fullName;
        Email = $email;
        ReviewCount = ($_.Count);
        IsOwner = $isOwner;
      };
    } | 
    Sort-Object ReviewCount -Descending;

  Write-Progress -Activity "Get-ReviewedBy" -Status "Done" -PercentComplete 100;

  $result;
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

function Watch-PullRequestIssues {
    param(
        [string] $Path = ".",
        [Alias("prid")] [string] $PullRequestId = $null,
        [string] $BuildErrors = "exclude",
        [int32] $WatchDelayInSeconds = 1 * 60
        );

    do {
      "---START LOG note---";
      ("Getting Issues $PullRequestId at " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"));
      "";

      Get-PullRequestIssues `
        -Path $Path `
        -BuildErrors $BuildErrors;

      "---END LOG note---";
      "";
      Start-Sleep $WatchDelayInSeconds;
    } while ($WatchDelayInSeconds -gt 0);
    
}

function Get-PullRequestIssues {
    param(
        [string] $Path = ".",
        [Alias("prid")] [string] $PullRequestId = $null,
        [string] $BuildErrors = "exclude"
        );

  if (git cl 2>&1 | Where-Object { $_ -match 'is not a git command' }) {
    Get-AdoPullRequestIssues @args;
  } else {
    Get-GerritPullRequestIssues @args;
  }
}

function Get-GerritPullRequestIssues {
  param(
    [string] $Path = ".",
    [ValidateSet("Text", "ErrorText", "PSObject")] [string] $OutputFormat = "Text",
    [string] $BuildErrors = "exclude"
  );

  # $BuildErrors: In the future consider using `git cl try-results -v -v --json=-` to get
  # the build errors from the try job. Not sure if there's a good way to get build error
  # details from that command. It has URL links to build details, but that doesn't look
  # easily parseable and requires auth.

  Push-Location $Path;

  $msgOutput = git cl comments -m -j -;

  Pop-Location;

  if ($msgOutput.Count -gt 1) {
    $msgJson = $msgOutput[-1];
  } else {
    $msgJson = $msgOutput;
  }

  $msgs = $msgJson | ConvertFrom-Json;
  $results = @();

  $msgs | ForEach-Object {
    $msg = $_;
    $patchSet = -1;
    # Format changed!
    # $msgContentChunks = $msg.message.Split("`n`n");

    # if ($msgContentChunks.Count -gt 1 -and $msgContentChunks[0] -match "Patch Set ([0-9]+)") {
    #   $patchSet = [int]$matches[1];
    # }

    # $msgContentChunks[2..($msgContentChunks.Count - 1)] | ForEach-Object {
    #   $msgContentChunk = $_;
    #   if ($msgContentChunk -match "([^:]+):([0-9]+):[^\n]+\n(.*)") {
    #     $file = $matches[1];
    #     $line = [int]$matches[2];
    #     $column = 1;
    #     $text = $matches[3];

    #     $results += @(New-Object PSObject @{
    #       "file"=$file;
    #       "line"=$line;
    #       "column"=$column;
    #       "text"=$text;
    #       "patchset"=$patchSet;
    #       "sender"=$msg.sender;
    #       "date"=([datetime]$msg.date);
    #     });
    #   }
    # }

    $msg.message | %{
      if ($_.message -match "Patch Set ([0-9]+)") {
        $messagePatchSet = [int]$matches[1];
      }
      $_.comments | %{
        $patchSet = $messagePatchSet;
        if ($_.patchset -and $_.patchset -match "PS([0-9]+)") {
          $patchSet = [int]$matches[1];
        }
        $date = ([datetime]$msg.date);
        $sender = $msg.sender;
        $file = $_.path;
        $line = $_.line;
        $column = 1;
        $text = $_.content;

        $results += @(New-Object PSObject @{
          "file"=$file;
          "line"=$line;
          "column"=$column;
          "text"=$text;
          "patchset"=$patchSet;
          "sender"=$sender;
          "date"=$date;
        });
      }
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
            $results;
        }
    } 
  }
}

function Get-AdoPullRequestIssues {
    param(
        [string] $Path = ".",
        [Alias("prid")] [string] $PullRequestId,
        [string] $Organization,
        [string[]] $ProjectNames,
        [string[]] $RepositoryNames,
        [string[]] $BranchNames = @(),
        [ValidateSet("Text", "ErrorText", "PSObject")] [string] $OutputFormat = "Text",
        [string] $BuildErrors = "exclude"
        );
    
    Push-Location $Path;

    $repositoryInfo = Get-AdoRepositoryInfo;
    $organizationUri = if ($Organization) {
      if ($Organization -match "^https?://") {
        $Organization.TrimEnd("/");
      } else {
        "https://dev.azure.com/$Organization";
      }
    } else {
      $repositoryInfo.OrganizationUri;
    }
    $projectName = if ($ProjectNames) { @($ProjectNames)[0] } else { $repositoryInfo.Project };
    $repoName = if ($RepositoryNames) { @($RepositoryNames)[0] } else { $repositoryInfo.Repository };
  
    if (!($BranchNames)) {
      $BranchNames = (git rev-parse --abbrev-ref HEAD);
    }

    if (!$PullRequestId) {
        $PullRequestId = Get-AdoPullRequestForBranch `
          -Organization $organizationUri `
          -ProjectNames @($projectName) `
          -RepositoryNames @($repoName) `
          -BranchNames @($BranchNames);
    }
  
    $BranchNames = @($BranchNames);

    $results = @();
    
    $result = Invoke-AzCli -Arguments @(
      "devops", "invoke",
      "--organization", $organizationUri,
      "--area", "git",
      "--resource", "pullRequestThreads",
      "--route-parameters", "project=$projectName", "repositoryId=$repoName", "pullRequestId=$PullRequestId",
      "--http-method", "GET",
      "--api-version", "7.1"
    );
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
        $_.comments | Where-Object { $_.content } | ForEach-Object {
          $_.content.split("`n") | Where-Object { $_.Contains("Failed"); } | ForEach-Object {
              if ($_ -match "buildId=([0-9]+)") {
                $matches[1];
              }
            }
          }
        }) | Where-Object { $_ };
      $buildIds | ForEach-Object {
        $buildId = $_;
        $timelineResult = Invoke-AzCli -Arguments @(
          "devops", "invoke",
          "--organization", $organizationUri,
          "--area", "build",
          "--resource", "timeline",
          "--route-parameters", "project=$projectName", "buildId=$buildId",
          "--http-method", "GET",
          "--api-version", "7.1"
        );
        $timelineResult.records | Where-Object { $_.issues } | ForEach-Object {
          $logResult = Invoke-AzCli -OutputFormat Text -Arguments @(
            "devops", "invoke",
            "--organization", $organizationUri,
            "--area", "build",
            "--resource", "logs",
            "--route-parameters", "project=$projectName", "buildId=$buildId", "logId=$($_.log.id)",
            "--http-method", "GET",
            "--api-version", "7.1"
          );
          $logResult.Split("`n") | Where-Object { $_.Contains(" error:") } | ForEach-Object {
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

    Pop-Location;
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
    
    Push-Location $Path;

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
    # $repoName = $RepositoryNames[0];
  
    # $fullUri = "https://$ApiHost/$Organization/$ProjectNames/$ApiName/$repoName/pullRequests/$PullRequestId/threads?api-version=7.1-preview.1";
    $fullUri = ("https://$ApiHost/$Organization/$ProjectNames/$ApiName/$BuildId" + "?api-version=7.1-preview.1");
  
    $user = "";
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $user,$AuthenticationPersonalAccessToken)));
  
    Write-Verbose $fullUri

    $result = (Invoke-RestMethod -Uri $fullUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});
    $fullUri = $result.url;
    $result = (Invoke-RestMethod -Uri $fullUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});

    $result;

    Pop-Location;
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
    
    Push-Location $Path;

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
    # $repoName = $RepositoryNames[0];
  
    # $fullUri = "https://$ApiHost/$Organization/$ProjectNames/$ApiName/$repoName/pullRequests/$PullRequestId/threads?api-version=7.1-preview.1";
    $fullUri = ("https://$ApiHost/$Organization/$ProjectNames/$ApiName/$BuildId/logs/$LogId" + "?api-version=7.1-preview.2");
  
    $user = "";
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $user,$AuthenticationPersonalAccessToken)));
  
    Write-Verbose $fullUri

    $result = (Invoke-RestMethod -Uri $fullUri -Method Get -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)});
    $result;

    Pop-Location;
}

function Get-AdoPullRequestForBranch {
  [CmdletBinding()]
  param(
    [string] $Organization,
    [string[]] $ProjectNames,
    [string[]] $RepositoryNames,
    [string[]] $BranchNames = @(),
    [ValidateSet("Id", "Uri", "PSObject")] [string] $OutputFormat = "Id"
  );

  $repositoryInfo = Get-AdoRepositoryInfo;
  $organizationUri = if ($Organization) {
    if ($Organization -match "^https?://") {
      $Organization.TrimEnd("/");
    } else {
      "https://dev.azure.com/$Organization";
    }
  } else {
    $repositoryInfo.OrganizationUri;
  }
  $projectName = if ($ProjectNames) { @($ProjectNames)[0] } else { $repositoryInfo.Project };
  $repositoryName = if ($RepositoryNames) { @($RepositoryNames)[0] } else { $repositoryInfo.Repository };

  if (!($BranchNames)) {
    $BranchNames = @((git rev-parse --abbrev-ref HEAD));
  }
  $branchName = @($BranchNames)[0];

  $pullRequests = @(Invoke-AzCli -Arguments @(
    "repos", "pr", "list",
    "--organization", $organizationUri,
    "--project", $projectName,
    "--repository", $repositoryName,
    "--source-branch", $branchName,
    "--status", "all"
  ));

  switch ($OutputFormat) {
    "Id" {
      $pullRequests | ForEach-Object {
        $_.pullRequestId;
      }
    }

    "Uri" {
      $pullRequests | ForEach-Object {
        "$($repositoryInfo.Remote)/pullrequest/$($_.pullRequestId)";
      }
    }

    "PSObject" {
      [PSCustomObject] @{
        count = $pullRequests.Count;
        value = $pullRequests;
      };
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


function DevStatus {
  @() + 
    @(Find-DevEnvironmentEnlistment | %{ join-path $_.root "depot_tools*" }) + 
    @(Find-DevEnvironmentEnlistment | %{ join-path $_.root "src" }) + 
    @(join-path $env:USERPROFILE "source\repos\*") | %{ get-gitpathpullrequeststatus $_ } | %{
      $path = $_.Path;
      # Use OSC 8 hyperlink to make the Path clickable to the path
      $pathAsLink = Format-TerminalClickableString $path $path;

      $emojiForRepo = repoEmoji $_.Path;

      $output = " $emojiForRepo " + $pathAsLink;

      $pathParts = $path -split "[\\/]";
      $ignoreBranches = @("main", "master", "HEAD");
      if (!($pathParts[$pathParts.Count - 1].Contains(".")) -and -not ($ignoreBranches -contains $_.Branch)) {
        $output += ", " + $_.Branch;
      }

      if ($_.PR) {
        $status = $_.Status;
        $pr = $_.PR;
        $prUrl = $_.PRUri;
        $prAsLink = Format-TerminalClickableString $prUrl $pr;

        $output += ", " + $prAsLink + " ($status)";
      }

      $output;
  }
}