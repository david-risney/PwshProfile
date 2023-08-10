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

function New-PullRequest {
  Start-Process (Get-GitPullRequestUri);
}

New-Alias Create-PullRequest New-PullRequest;

# Function to get the URI of the current git repo set
# to the specificed path.
function Get-GitUri {
  param($Path);

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

function Get-GitChangePaths {
  [CmdletBinding()]
  param(
    $SetPathMatch,
    [switch] $FullPaths,
    [switch] $OnlyGitStatusFiles,
    [switch] $RebuildCache,
    $BranchCommit);

  if (!$global:gitChangePathsCache -or $RebuildCache) {
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
    $global:gitChangePathsCache = $gitFiles;
  } else {
    Write-Verbose "Using cached git change paths";
  }

  $gitFiles = $global:gitChangePathsCache;

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
