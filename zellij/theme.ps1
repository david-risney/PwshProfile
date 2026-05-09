[CmdletBinding(DefaultParameterSetName = "Named")]
param(
    [Parameter(ParameterSetName = "Named", Position = 0)]
    [string]$Theme,

    [Parameter(ParameterSetName = "Next")]
    [switch]$Next,

    [Parameter(ParameterSetName = "Prev")]
    [switch]$Prev
)

$configPath = "$PSScriptRoot\config.kdl"

$themes = @(
    "ansi"
    "ao"
    "atelier"
    "ayu-dark"
    "ayu-light"
    "ayu-mirage"
    "blade-runner"
    "catppuccin-frappe"
    "catppuccin-latte"
    "catppuccin-macchiato"
    "catppuccin-mocha"
    "cyber-noir"
    "dayfox"
    "dracula"
    "everforest-dark"
    "everforest-light"
    "flexoki-dark"
    "gruber-darker"
    "gruvbox-dark"
    "gruvbox-light"
    "iceberg-dark"
    "iceberg-light"
    "kanagawa"
    "lucario"
    "menace"
    "molokai-dark"
    "night-owl"
    "nightfox"
    "nord"
    "one-half-dark"
    "onedark"
    "pencil-light"
    "retro-wave"
    "solarized-dark"
    "solarized-light"
    "terafox"
    "tokyo-night-dark"
    "tokyo-night-light"
    "tokyo-night-storm"
    "tokyo-night"
    "vesper"
)

$content = Get-Content $configPath -Raw
$currentTheme = if ($content -match 'theme "([^"]+)"') { $Matches[1] } else { $null }

if (-not $currentTheme) {
    Write-Error "Could not find a theme line in $configPath"
    exit 1
}

if ($Next -or $Prev) {
    $idx = [array]::IndexOf($themes, $currentTheme)
    if ($idx -eq -1) {
        Write-Error "Current theme '$currentTheme' is not in the known themes list."
        exit 1
    }
    if ($Next) {
        $idx = ($idx + 1) % $themes.Count
    } else {
        $idx = ($idx - 1 + $themes.Count) % $themes.Count
    }
    $Theme = $themes[$idx]
}

if (-not $Theme) {
    Write-Host "Current theme: $currentTheme"
    Write-Host ""
    for ($i = 0; $i -lt $themes.Count; $i++) {
        $marker = if ($themes[$i] -eq $currentTheme) { " *" } else { "" }
        Write-Host ("  {0,2}. {1}{2}" -f ($i + 1), $themes[$i], $marker)
    }
    Write-Host ""
    $selection = Read-Host "Enter theme name or number"
    if ($selection -match '^\d+$') {
        $idx = [int]$selection - 1
        if ($idx -lt 0 -or $idx -ge $themes.Count) {
            Write-Error "Invalid number."
            exit 1
        }
        $Theme = $themes[$idx]
    } else {
        $Theme = $selection
    }
}

if ($Theme -notin $themes) {
    Write-Error "Unknown theme '$Theme'. Valid themes: $($themes -join ', ')"
    exit 1
}

$newContent = $content -replace "theme `"$([regex]::Escape($currentTheme))`"", "theme `"$Theme`""
Set-Content $configPath $newContent -NoNewline
Write-Host "Theme changed: $currentTheme -> $Theme"
