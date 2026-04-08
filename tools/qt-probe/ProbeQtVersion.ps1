<#
.SYNOPSIS
    Probes a single Qt version for strict support of -c++std c++23 and -no-emojisegmenter.

.DESCRIPTION
    Downloads qt-everywhere-src-<QtVersion>.zip from download.qt.io, extracts it to a
    temporary directory, then performs TWO checks with zero workaround policy:

    CHECK 1 – Help scan
      Runs: qtbase\configure.bat -top-level -help
      Verifies:
        a) output contains "-no-emojisegmenter"
        b) output contains "-c++std"
        c) output contains "c++23" (as a valid value for -c++std)

    CHECK 2 – Smoke configure (no build)
      Runs configure.bat with the EXACT production flags (no fallback, no substitution).
      A non-zero exit code → FAIL.

    Both checks must pass for the version to be PASS.

    Writes to -OutDir:
      result-<ver>.json   full machine-readable result
      result-<ver>.md     human-readable PASS/FAIL summary
      configure-smoke-<ver>.log  raw configure output (smoke step)

.PARAMETER QtVersion
    Version string, e.g. "6.9.1".

.PARAMETER OutDir
    Directory where JSON / MD / log files are written.  Created if absent.

.PARAMETER WorkDir
    Base directory for downloading and extracting Qt sources.
    Defaults to $env:RUNNER_TEMP\qt-probe-<ver> (CI) or $env:TEMP\qt-probe-<ver> (local).

.EXAMPLE
    .\ProbeQtVersion.ps1 -QtVersion 6.9.1 -OutDir .\reports

.EXAMPLE
    .\ProbeQtVersion.ps1 -QtVersion 6.11.2 -OutDir C:\probe-out -WorkDir D:\tmp\qt-work
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$QtVersion,

    [Parameter(Mandatory = $true)]
    [string]$OutDir,

    [Parameter(Mandatory = $false)]
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Json {
    param([string]$Path, [object]$Obj)
    $Obj | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not $WorkDir) {
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
    $WorkDir = Join-Path $base "qt-probe-$QtVersion"
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$majMin  = ($QtVersion -split '\.')[0..1] -join '.'
$zipName = "qt-everywhere-src-$QtVersion.zip"
$zipUrl  = "https://download.qt.io/official_releases/qt/$majMin/$QtVersion/single/$zipName"
$zipPath = Join-Path $WorkDir $zipName
$srcDir  = Join-Path $WorkDir "qt-src-$QtVersion"

# ---------------------------------------------------------------------------
# Result structure
# ---------------------------------------------------------------------------
$result = [ordered]@{
    qt_version = $QtVersion
    url        = $zipUrl
    ok         = $false
    checks     = [ordered]@{
        has_no_emojisegmenter  = $false
        has_cxxstd             = $false
        mentions_cxx23         = $false
        configure_smoke_ok     = $false
    }
    error      = ''
}

# ---------------------------------------------------------------------------
# Main probe
# ---------------------------------------------------------------------------
try {
    # ---- Download -----------------------------------------------------------
    Write-Host "==> Downloading Qt $QtVersion"
    Write-Host "    URL : $zipUrl"
    & curl.exe -fsSL $zipUrl -o $zipPath
    if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }

    # ---- Extract ------------------------------------------------------------
    Write-Host "==> Extracting $zipPath"
    & tar.exe -xf $zipPath -C $WorkDir
    if ($LASTEXITCODE -ne 0) { throw "tar extract failed with exit code $LASTEXITCODE" }

    $extracted = Join-Path $WorkDir "qt-everywhere-src-$QtVersion"
    if (-not (Test-Path $extracted)) {
        throw "Expected extracted directory not found: $extracted"
    }
    Move-Item $extracted $srcDir

    # ---- Locate configure.bat -----------------------------------------------
    $configureBat = Join-Path $srcDir "qtbase\configure.bat"
    if (-not (Test-Path $configureBat)) {
        throw "configure.bat not found: $configureBat"
    }

    # ---- CHECK 1: Help scan -------------------------------------------------
    Write-Host "==> Running configure -help for Qt $QtVersion"
    $helpOutput = & $configureBat -top-level -help 2>&1 | Out-String

    $result.checks.has_no_emojisegmenter = [bool]($helpOutput -match '(-no-emojisegmenter)')
    $result.checks.has_cxxstd            = [bool]($helpOutput -match '(-c\+\+std)')
    $result.checks.mentions_cxx23        = [bool]($helpOutput -match '(c\+\+23)')

    Write-Host "    -no-emojisegmenter in help : $($result.checks.has_no_emojisegmenter)"
    Write-Host "    -c++std in help            : $($result.checks.has_cxxstd)"
    Write-Host "    c++23 mentioned in help    : $($result.checks.mentions_cxx23)"

    if (-not $result.checks.has_no_emojisegmenter) {
        throw "CHECK 1 FAIL: '-no-emojisegmenter' not found in configure -help output"
    }
    if (-not $result.checks.has_cxxstd) {
        throw "CHECK 1 FAIL: '-c++std' not found in configure -help output"
    }
    if (-not $result.checks.mentions_cxx23) {
        throw "CHECK 1 FAIL: 'c++23' not found in configure -help output (not a valid value for -c++std)"
    }

    # ---- CHECK 2: Smoke configure (no build) --------------------------------
    Write-Host "==> Running smoke configure for Qt $QtVersion (no build)"
    $smokeBuildDir = Join-Path $WorkDir "smoke-build"
    New-Item -ItemType Directory -Force -Path $smokeBuildDir | Out-Null
    $installPrefix = Join-Path $WorkDir "qt-install-smoke"

    # EXACT flags — no fallback, no substitution.
    # '-c++std c++23' requires Qt to explicitly advertise 'c++23' as a valid value; the probe
    # verifies this in CHECK 1 before attempting the smoke configure.
    $configureArgs = @(
        '-top-level',
        '-prefix',       $installPrefix,
        '-c++std',       'c++23',
        '-platform',     'win32-msvc',
        '-ltcg',
        '-static',
        '-static-runtime',
        '-release',
        '-nomake',       'tests',
        '-nomake',       'examples',
        '-nomake',       'benchmarks',
        '-no-feature-testlib',
        '-no-opengl',
        '-qt-harfbuzz',
        '-qt-freetype',
        '-qt-libpng',
        '-qt-libjpeg',
        '-qt-webp',
        '-qt-tiff',
        '-qt-zlib',
        '-qt-doubleconversion',
        '-qt-pcre',
        '-no-emojisegmenter',
        '-no-icu',
        '-no-gif',
        '-gui',
        '-widgets',
        '-submodules',   'qtbase,qtimageformats,qttools',
        '-qpa',          'windows',
        # 0x068200 = QT_VERSION_CHECK(6, 0x82, 0); disables all APIs deprecated before this version.
        # Adjust this value to match the target Qt baseline for your project.
        '-disable-deprecated-up-to', '0x068200',
        'QT_SKIP_EXCEPTIONS=ON'
    )

    $smokeLogPath = Join-Path $OutDir "configure-smoke-$QtVersion.log"

    Push-Location $smokeBuildDir
    try {
        $smokeOutput = & $configureBat @configureArgs 2>&1 | Out-String
        $smokeExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $smokeOutput | Set-Content -Path $smokeLogPath -Encoding UTF8
    Write-Host "    Smoke configure exit code: $smokeExitCode"
    Write-Host "    Log written to: $smokeLogPath"

    if ($smokeExitCode -ne 0) {
        throw "CHECK 2 FAIL: smoke configure exited with code $smokeExitCode (see $smokeLogPath)"
    }

    $result.checks.configure_smoke_ok = $true
    $result.ok = $true
    Write-Host "==> RESULT: PASS  (Qt $QtVersion)"

} catch {
    $result.error = $_.Exception.Message
    Write-Host "==> RESULT: FAIL  (Qt $QtVersion)"
    Write-Host "    Reason: $($result.error)"
}

# ---------------------------------------------------------------------------
# Write output files
# ---------------------------------------------------------------------------
$jsonPath = Join-Path $OutDir "result-$QtVersion.json"
Write-Json $jsonPath $result

$passOrFail = if ($result.ok) { 'PASS' } else { 'FAIL' }
$mdLines = @(
    "### Qt $QtVersion — $passOrFail",
    '',
    "| Check | Result |",
    "| ----- | ------ |",
    "| `-no-emojisegmenter` in help | $($result.checks.has_no_emojisegmenter) |",
    "| `-c++std` in help            | $($result.checks.has_cxxstd) |",
    "| `c++23` mentioned in help    | $($result.checks.mentions_cxx23) |",
    "| smoke configure (exact flags) | $($result.checks.configure_smoke_ok) |"
)
if ($result.error) {
    $mdLines += ''
    $mdLines += "> **Error:** $($result.error)"
}
$mdLines += ''

$mdPath = Join-Path $OutDir "result-$QtVersion.md"
($mdLines -join "`n") | Set-Content -Path $mdPath -Encoding UTF8

Write-Host "    JSON : $jsonPath"
Write-Host "    MD   : $mdPath"

# Return the result object so callers can inspect $result.ok
return $result
