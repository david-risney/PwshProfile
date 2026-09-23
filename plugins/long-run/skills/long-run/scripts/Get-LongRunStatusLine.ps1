[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,

    [string]$StateRoot = (Join-Path $env:TEMP 'long-run'),

    [string]$Label = 'long-run'
)

$ErrorActionPreference = 'Stop'

function ConvertTo-CanonicalPath([string]$Path) {
    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar)
    } catch {
        return $null
    }
}

function Test-OwnerProcess([object]$Metadata) {
    if (-not $Metadata.ownerPid -or -not $Metadata.ownerStartedAtUnixMs) {
        return $false
    }

    try {
        $owner = Get-Process -Id ([int]$Metadata.ownerPid) -ErrorAction Stop
        $actualStart = [DateTimeOffset]::new(
            $owner.StartTime).ToUnixTimeMilliseconds()
        return [Math]::Abs(
            $actualStart - [long]$Metadata.ownerStartedAtUnixMs) -lt 2000
    } catch {
        return $false
    }
}

$canonicalWorkingDirectory = ConvertTo-CanonicalPath $WorkingDirectory
if (-not $canonicalWorkingDirectory -or -not (Test-Path -LiteralPath $StateRoot)) {
    return
}

$active = Get-ChildItem -LiteralPath $StateRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        $metadataPath = Join-Path $_.FullName 'session.json'
        if (-not (Test-Path -LiteralPath $metadataPath)) { return }

        try {
            $metadata = [System.IO.File]::ReadAllText($metadataPath) |
                ConvertFrom-Json
            $metadataDirectory = ConvertTo-CanonicalPath (
                [string]$metadata.workingDirectory)
            if ($metadataDirectory -ne $canonicalWorkingDirectory -or
                -not $metadata.remoteUrl -or
                -not (Test-OwnerProcess $metadata)) {
                return
            }

            $url = [string]$metadata.remoteUrl
            if ($url -match '[\x00-\x1f\x7f]' -or
                -not [Uri]::IsWellFormedUriString(
                    $url, [UriKind]::Absolute)) {
                return
            }
            $uri = [Uri]$url
            if ($uri.Scheme -notin @('http', 'https')) { return }

            [pscustomobject]@{
                StartedAt = [DateTimeOffset]::Parse([string]$metadata.startedAt)
                Url = $url
            }
        } catch {
            return
        }
    } |
    Sort-Object StartedAt -Descending |
    Select-Object -First 1

if (-not $active) { return }

$safeLabel = $Label -replace '[\x00-\x1f\x7f]', ''
$escape = [char]27
return (
    $escape + ']8;;' + $active.Url + $escape + '\' +
    $safeLabel +
    $escape + ']8;;' + $escape + '\')
