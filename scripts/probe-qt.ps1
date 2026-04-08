param(
  [Parameter(Mandatory=$true)][string]$QtVersion,
  [Parameter(Mandatory=$true)][string]$OutDir
)

$ErrorActionPreference = "Stop"

function Write-Json($path, $obj) {
  $obj | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$work = Join-Path $env:RUNNER_TEMP "qt-probe-$QtVersion"
New-Item -ItemType Directory -Force -Path $work | Out-Null

$majMin = ($QtVersion -split '\.')[0..1] -join '.'
$zipName = "qt-everywhere-src-$QtVersion.zip"
$url = "https://download.qt.io/official_releases/qt/$majMin/$QtVersion/single/$zipName"
$zipPath = Join-Path $work $zipName
$srcDir = Join-Path $work "qt-src-$QtVersion"

$result = [ordered]@{
  qt_version = $QtVersion
  url = $url
  ok = $false
  checks = [ordered]@{
    has_no_emojisegmenter = $false
    has_cxxstd = $false
    mentions_cxx23 = $false
    configure_smoke_ok = $false
  }
  error = ""
}

try {
  Write-Host "Downloading $url"
  & curl.exe -L $url -o $zipPath
  if ($LASTEXITCODE -ne 0) { throw "curl failed ($LASTEXITCODE)" }

  Write-Host "Extracting $zipPath"
  & tar.exe -xf $zipPath -C $work
  if ($LASTEXITCODE -ne 0) { throw "tar extract failed ($LASTEXITCODE)" }

  $extracted = Join-Path $work "qt-everywhere-src-$QtVersion"
  if (-not (Test-Path $extracted)) { throw "Expected extracted dir missing: $extracted" }
  Move-Item $extracted $srcDir

  $cfg = Join-Path $srcDir "qtbase\configure.bat"
  if (-not (Test-Path $cfg)) { throw "configure.bat missing: $cfg" }

  Write-Host "Running configure -help"
  $help = & $cfg -top-level -help 2>&1 | Out-String

  $result.checks.has_no_emojisegmenter = ($help -match "(-no-emojisegmenter)")
  $result.checks.has_cxxstd            = ($help -match "(-c\+\+std)")
  $result.checks.mentions_cxx23        = ($help -match "(c\+\+23)")

  if (-not $result.checks.has_no_emojisegmenter) { throw "Missing flag: -no-emojisegmenter" }
  if (-not $result.checks.has_cxxstd)            { throw "Missing flag: -c++std" }
  if (-not $result.checks.mentions_cxx23)        { throw "Help does not mention c++23 under -c++std" }

  # strict smoke configure: use the exact flags; if it fails -> FAIL.
  $smokeBuild = Join-Path $work "smoke-build"
  New-Item -ItemType Directory -Force -Path $smokeBuild | Out-Null
  Push-Location $smokeBuild

  $prefix = Join-Path $work "qt-install-smoke"
  $args = @(
    "-top-level",
    "-prefix", $prefix,
    "-c++std", "c++23",
    "-platform", "win32-msvc",
    "-ltcg",
    "-static",
    "-static-runtime",
    "-release",
    "-nomake", "tests",
    "-nomake", "examples",
    "-nomake", "benchmarks",
    "-no-feature-testlib",
    "-no-opengl",
    "-qt-harfbuzz",
    "-qt-freetype",
    "-qt-libpng",
    "-qt-libjpeg",
    "-qt-webp",
    "-qt-tiff",
    "-qt-zlib",
    "-qt-doubleconversion",
    "-qt-pcre",
    "-no-emojisegmenter",
    "-no-icu",
    "-no-gif",
    "-gui",
    "-widgets",
    "-submodules", "qtbase,qtimageformats,qttools",
    "-qpa", "windows",
    "-disable-deprecated-up-to", "0x068200",
    "QT_SKIP_EXCEPTIONS=ON"
  )

  & $cfg @args 2>&1 | Out-String | Set-Content -Path (Join-Path $OutDir "configure-smoke-$QtVersion.log") -Encoding UTF8
  if ($LASTEXITCODE -ne 0) { throw "configure smoke failed ($LASTEXITCODE)" }

  $result.checks.configure_smoke_ok = $true
  $result.ok = $true

  Pop-Location
} catch {
  $result.error = $_.Exception.Message
  try { Pop-Location } catch {}
}

Write-Json (Join-Path $OutDir "result-$QtVersion.json") $result

@(
  "### Qt $QtVersion",
  "",
  "- OK: **$($result.ok)**",
  "- has `-no-emojisegmenter`: $($result.checks.has_no_emojisegmenter)",
  "- has `-c++std`: $($result.checks.has_cxxstd)",
  "- mentions `c++23`: $($result.checks.mentions_cxx23)",
  "- smoke configure (exact flags) OK: $($result.checks.configure_smoke_ok)",
  $(if ($result.error) { "- error: ``$($result.error)``" } else { "" }),
  ""
) -join "`n" | Set-Content -Path (Join-Path $OutDir "result-$QtVersion.md") -Encoding UTF8
