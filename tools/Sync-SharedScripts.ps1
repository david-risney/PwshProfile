<#
.SYNOPSIS
Sync (or verify) the vendored copies of the shared helper scripts.

.DESCRIPTION
Some helper scripts live once as a source of truth under shared\ and are copied
("vendored") into each plugin's scripts\ folder so every plugin stays
self-contained. This script copies each source file to its registered
destinations, injecting a header banner that marks the copy as generated so
nobody edits it by hand.

.PARAMETER Check
Don't write anything. Instead verify every destination is byte-for-byte in sync
with what would be generated, and exit 1 if any are stale. Intended for CI /
pre-commit.

.EXAMPLE
tools\Sync-SharedScripts.ps1            # write/update all vendored copies
tools\Sync-SharedScripts.ps1 -Check     # verify only (non-zero exit if stale)
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# Map: source file (under repo root) -> one or more vendored destinations.
$map = @(
    @{
        Source = 'shared\Terminal-Panes.ps1'
        Dests  = @(
            'plugins\copilot-session\skills\copilot-session\scripts\Terminal-Panes.ps1',
            'plugins\long-run\skills\long-run\scripts\Terminal-Panes.ps1'
        )
    }
)

function Get-VendoredText([string]$sourcePath) {
    $rel = $sourcePath.Substring($repoRoot.Length).TrimStart('\', '/')
    $banner = @(
        '# ============================================================================',
        '# GENERATED FILE -- DO NOT EDIT.',
        "# Vendored copy of $($rel -replace '\\','/').",
        '# Edit the source, then run tools\Sync-SharedScripts.ps1 to regenerate.',
        '# ============================================================================',
        ''
    ) -join "`r`n"
    $body = Get-Content -LiteralPath $sourcePath -Raw
    return $banner + "`r`n" + $body
}

$stale = @()
foreach ($entry in $map) {
    $src = Join-Path $repoRoot $entry.Source
    if (-not (Test-Path -LiteralPath $src)) { throw "Missing source: $src" }
    $expected = Get-VendoredText $src
    foreach ($destRel in $entry.Dests) {
        $dest = Join-Path $repoRoot $destRel
        $current = if (Test-Path -LiteralPath $dest) { Get-Content -LiteralPath $dest -Raw } else { $null }
        if ($Check) {
            if ($current -ne $expected) { $stale += $destRel }
        } else {
            $dir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            Set-Content -LiteralPath $dest -Value $expected -NoNewline -Encoding UTF8
            Write-Host "synced -> $destRel"
        }
    }
}

if ($Check) {
    if ($stale.Count) {
        Write-Host "Out of sync (run tools\Sync-SharedScripts.ps1):" -ForegroundColor Red
        $stale | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host 'All vendored shared scripts are in sync.' -ForegroundColor Green
}
