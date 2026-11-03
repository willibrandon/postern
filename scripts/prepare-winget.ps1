param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestDirectory
)

$ErrorActionPreference = 'Stop'

# WingetCreate can emit an older schema than the community repository accepts.
# Keep generated manifests at least as recent as our checked-in templates.
$template = Get-Content "$PSScriptRoot/../winget/willibrandon.postern.yaml" -Raw
$minimum = [regex]::Match($template, '(?m)^ManifestVersion: ([0-9.]+)').Groups[1].Value
if (-not $minimum) { throw 'The WinGet template has no ManifestVersion.' }

$files = @(Get-ChildItem -LiteralPath $ManifestDirectory -Filter '*.yaml' -File)
if ($files.Count -lt 3) { throw 'Expected a complete WinGet manifest set.' }

foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    $version = [regex]::Match($content, '(?m)^ManifestVersion: ([0-9.]+)').Groups[1].Value
    $type = [regex]::Match($content, '(?m)^ManifestType: (\w+)').Groups[1].Value
    if (-not $version -or $type -notin @('version', 'installer', 'defaultLocale', 'locale')) {
        throw "Missing or unsupported manifest metadata in $($file.Name)."
    }
    if ([version]$version -lt [version]$minimum) { $version = $minimum }

    $content = $content -replace '(?m)^ManifestVersion: [0-9.]+', "ManifestVersion: $version"
    $header = '# yaml-language-server: $schema=https://aka.ms/winget-manifest.' + "$type.$version.schema.json"
    if ($content -notmatch '(?m)^# yaml-language-server:') {
        throw "Missing schema header in $($file.Name)."
    }
    $content = $content -replace '(?m)^# yaml-language-server:[^\r\n]*', $header
    [System.IO.File]::WriteAllText($file.FullName, $content)
}

winget validate --manifest $ManifestDirectory --disable-interactivity
if ($LASTEXITCODE -ne 0) {
    throw "WinGet manifest validation failed with exit code $LASTEXITCODE."
}
