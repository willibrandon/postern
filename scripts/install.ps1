# Installs the postern binary for Windows from a GitHub release.
#
#   irm https://raw.githubusercontent.com/willibrandon/postern/main/scripts/install.ps1 | iex
#
# Parameters: -Dir for where the binary goes, $env:LOCALAPPDATA\Programs\postern
# without it, and -Version for a release other than the latest. The checksum
# the release carries is verified before the binary is put in place, and the
# path is printed at the end.
param(
  [string]$Dir = "$env:LOCALAPPDATA\Programs\postern",
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"

if ($Version -eq "") {
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/willibrandon/postern/releases/latest"
  $Version = $release.tag_name.TrimStart("v")
}

$asset = "postern-$Version-win32-x64.exe"
$base = "https://github.com/willibrandon/postern/releases/download/v$Version"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  Invoke-WebRequest -Uri "$base/$asset" -OutFile (Join-Path $tmp $asset)
  Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile (Join-Path $tmp "SHA256SUMS")
  $expected = (Get-Content (Join-Path $tmp "SHA256SUMS") | Where-Object { $_ -match " \*?$([regex]::Escape($asset))$" }) -split "\s+" | Select-Object -First 1
  $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $asset)).Hash.ToLower()
  if ($expected -ne $actual) { throw "the checksum of $asset does not match the release's SHA256SUMS" }
  New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  Move-Item -Force (Join-Path $tmp $asset) (Join-Path $Dir "postern.exe")
  Write-Output (Join-Path $Dir "postern.exe")
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
