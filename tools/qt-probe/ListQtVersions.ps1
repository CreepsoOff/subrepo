<#
.SYNOPSIS
    Lists all available Qt versions >= 6.9.0 from download.qt.io, sorted oldest-first.

.DESCRIPTION
    Queries https://download.qt.io/official_releases/qt/ to discover all published
    Qt 6.x minor series (6.9, 6.10, 6.11, ...) and their patch releases.
    Returns only versions >= 6.9.0.  Output is one version string per line.

.EXAMPLE
    .\ListQtVersions.ps1
    6.9.0
    6.9.1
    6.9.2
    ...

.EXAMPLE
    $versions = .\ListQtVersions.ps1
    foreach ($v in $versions) { Write-Host $v }
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Minimum version to include
$minMajor = 6
$minMinor = 9
$minPatch = 0

function Get-HtmlLinks {
    param([string]$Url)
    $html = (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content
    $matches = [regex]::Matches($html, 'href="([^"]+)"')
    return $matches | ForEach-Object { $_.Groups[1].Value }
}

function Parse-Version {
    param([string]$s)
    # Accepts "6.9.0" or "6.9.0/" style strings; strips trailing slash
    $s = $s.TrimEnd('/')
    $parts = $s -split '\.'
    if ($parts.Count -lt 3) { return $null }
    $maj = 0; $min = 0; $pat = 0
    if (-not [int]::TryParse($parts[0], [ref]$maj)) { return $null }
    if (-not [int]::TryParse($parts[1], [ref]$min)) { return $null }
    if (-not [int]::TryParse($parts[2], [ref]$pat)) { return $null }
    return [pscustomobject]@{ Major = $maj; Minor = $min; Patch = $pat; String = "$maj.$min.$pat" }
}

function Compare-QtVersion {
    param($a, $b)
    if ($a.Major -ne $b.Major) { return $a.Major.CompareTo($b.Major) }
    if ($a.Minor -ne $b.Minor) { return $a.Minor.CompareTo($b.Minor) }
    return $a.Patch.CompareTo($b.Patch)
}

$baseUrl = 'https://download.qt.io/official_releases/qt/'

# Step 1: get all major.minor series
Write-Verbose "Fetching minor series list from $baseUrl"
$minorLinks = Get-HtmlLinks -Url $baseUrl

$minorSeries = @()
foreach ($link in $minorLinks) {
    $clean = $link.TrimEnd('/')
    $parts = $clean -split '\.'
    if ($parts.Count -ne 2) { continue }
    $maj = 0; $min = 0
    if (-not [int]::TryParse($parts[0], [ref]$maj)) { continue }
    if (-not [int]::TryParse($parts[1], [ref]$min)) { continue }
    if ($maj -ne $minMajor) { continue }
    if ($min -lt $minMinor) { continue }
    $minorSeries += [pscustomobject]@{ Major = $maj; Minor = $min; Label = $clean }
}

# Step 2: for each minor series, enumerate patch versions
$allVersions = @()
foreach ($series in $minorSeries) {
    $seriesUrl = "${baseUrl}$($series.Label)/"
    Write-Verbose "Fetching patch list from $seriesUrl"
    try {
        $patchLinks = Get-HtmlLinks -Url $seriesUrl
    } catch {
        Write-Warning "Could not fetch $seriesUrl : $_"
        continue
    }

    foreach ($link in $patchLinks) {
        $clean = $link.TrimEnd('/')
        $v = Parse-Version $clean
        if ($null -eq $v) { continue }
        if ($v.Major -ne $series.Major -or $v.Minor -ne $series.Minor) { continue }
        # Enforce >= 6.9.0
        if ($v.Major -lt $minMajor) { continue }
        if ($v.Major -eq $minMajor -and $v.Minor -lt $minMinor) { continue }
        if ($v.Major -eq $minMajor -and $v.Minor -eq $minMinor -and $v.Patch -lt $minPatch) { continue }

        # Verify the single/ zip actually exists before advertising the version
        $zipName = "qt-everywhere-src-$($v.String).zip"
        $zipUrl  = "${baseUrl}$($series.Label)/$($v.String)/single/$zipName"
        Write-Verbose "Checking zip availability: $zipUrl"
        try {
            $head = Invoke-WebRequest -Uri $zipUrl -Method Head -UseBasicParsing
            if ($head.StatusCode -eq 200) {
                $allVersions += $v
            }
        } catch {
            Write-Verbose "Zip not available for $($v.String) ($zipUrl): $_"
        }
    }
}

# Step 3: sort oldest-first and output
$sorted = $allVersions | Sort-Object -Property @(
    { $_.Major }, { $_.Minor }, { $_.Patch }
)

foreach ($v in $sorted) {
    Write-Output $v.String
}
