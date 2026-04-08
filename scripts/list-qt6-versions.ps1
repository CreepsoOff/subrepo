<#
.SYNOPSIS
  List all Qt 6.x patch releases available on download.qt.io and write them to a JSON file.

.PARAMETER MinVersion
  Optional minimum minor version (e.g. "6.9"). Versions below this are skipped.

.PARAMETER OutFile
  Path for the output JSON file (array of version strings).
  Defaults to "qt6-versions.json" in the current directory.

.EXAMPLE
  ./list-qt6-versions.ps1 -MinVersion 6.9 -OutFile qt6-versions.json
#>
param(
  [string]$MinVersion = "",
  [string]$OutFile    = "qt6-versions.json"
)

$ErrorActionPreference = "Stop"

$baseUrl = "https://download.qt.io/official_releases/qt/"

Write-Host "Fetching Qt release index from $baseUrl"
$indexHtml = (Invoke-WebRequest -Uri $baseUrl -UseBasicParsing).Content

# Parse out all 6.<minor>/ directory links
function ConvertTo-SafeVersion([string]$v) {
  try { return [version]$v } catch { return [version]"0.0.0" }
}

$minorMatches = [regex]::Matches($indexHtml, 'href="(6\.\d+)/"')
if ($minorMatches.Count -eq 0) {
  throw "No Qt 6.x minor versions found at $baseUrl – check the URL/regex."
}

$minorVersions = $minorMatches |
  ForEach-Object { $_.Groups[1].Value } |
  Sort-Object    { ConvertTo-SafeVersion $_ }

Write-Host "Found minor series: $($minorVersions -join ', ')"

# Normalise MinVersion to "major.minor" so [version] cast always has two parts
$minVersionParsed = $null
if ($MinVersion -ne "") {
  try {
    $minVersionParsed = [version]$MinVersion
  } catch {
    throw "MinVersion '$MinVersion' is not a valid version string (expected e.g. '6.9')."
  }
}

$allVersions = [System.Collections.Generic.List[string]]::new()

foreach ($minor in $minorVersions) {
  if ($minVersionParsed -ne $null -and (ConvertTo-SafeVersion $minor) -lt $minVersionParsed) {
    Write-Host "Skipping $minor (below MinVersion $MinVersion)"
    continue
  }

  $minorUrl = "${baseUrl}${minor}/"
  Write-Host "Fetching patch list for Qt $minor ..."
  try {
    $minorHtml = (Invoke-WebRequest -Uri $minorUrl -UseBasicParsing).Content
  } catch {
    Write-Warning "Failed to fetch ${minorUrl}: $_"
    continue
  }

  # Parse out all <minor>.<patch>/ directory links
  $escapedMinor = [regex]::Escape($minor)
  $patchMatches = [regex]::Matches($minorHtml, 'href="(' + $escapedMinor + '\.\d+)/"')
  if ($patchMatches.Count -eq 0) {
    Write-Warning "No patch versions found under $minorUrl"
    continue
  }

  $patches = $patchMatches |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object    { ConvertTo-SafeVersion $_ }

  foreach ($v in $patches) {
    $allVersions.Add($v)
  }
}

if ($allVersions.Count -eq 0) {
  throw "No Qt 6.x versions discovered – aborting."
}

$json = $allVersions | ConvertTo-Json -Compress
$json | Set-Content -Path $OutFile -Encoding UTF8

Write-Host "Wrote $($allVersions.Count) version(s) to $OutFile"
Write-Host "Versions: $($allVersions -join ', ')"
