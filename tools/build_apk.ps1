# Build the two APK variants:
#   -Test:    models bundled (fully offline, ~152MB)
#   -Release: models excluded, downloaded in-app on first use (~80MB)
# Usage: powershell -File tools/build_apk.ps1 -Test   (or -Release)
param(
    [switch]$Test,
    [switch]$Release
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$pub = Join-Path $root "example\pubspec.yaml"
$onnxDir = Join-Path $root "example\assets\onnx"
$stash = Join-Path $env:TEMP "onnx-stash-bwm"
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$assetLines = @(
    "  assets:",
    "    - assets/",
    "    - assets/onnx/wam_embedder.onnx",
    "    - assets/onnx/wam_extractor_int8.onnx"
)

function Set-PubspecModels($present) {
    $c = Get-Content $pub -Raw
    if ($present) {
        if (-not $c.Contains("assets/onnx/wam_embedder.onnx")) {
            $c = $c.Replace("    - assets/`n", "    - assets/`n    - assets/onnx/wam_embedder.onnx`n    - assets/onnx/wam_extractor_int8.onnx`n")
        }
    } else {
        $c = $c -replace "(?m)^    - assets/onnx/.*`r?`n", ""
    }
    Set-Content $pub $c -Encoding UTF8
}

if ($Release) {
    Write-Host "== Release build (models NOT bundled) =="
    New-Item -ItemType Directory -Force -Path $stash | Out-Null
    Get-ChildItem $onnxDir -File | Move-Item -Destination $stash -Force
    Set-PubspecModels $false
} else {
    Write-Host "== Test build (models bundled) =="
    if (Test-Path $stash) {
        Get-ChildItem $stash -File | Move-Item -Destination $onnxDir -Force
        Remove-Item $stash -Recurse -Force
    }
    Set-PubspecModels $true
}

Push-Location (Join-Path $root "example")
try {
    flutter clean | Out-Null
    flutter pub get | Out-Null
    flutter build apk --release
    if ($LASTEXITCODE -ne 0) { throw "build failed" }
} finally {
    Pop-Location
}

if ($Release) {
    Get-ChildItem $stash -File | Move-Item -Destination $onnxDir -Force
    Remove-Item $stash -Recurse -Force
    Set-PubspecModels $true
    Copy-Item (Join-Path $root "example\build\app\outputs\flutter-apk\app-release.apk") `
        (Join-Path $dist "盲水印-v1.1.0-发布版-在线下载模型.apk") -Force
} else {
    Copy-Item (Join-Path $root "example\build\app\outputs\flutter-apk\app-release.apk") `
        (Join-Path $dist "盲水印-v1.1.0-测试版-内置模型.apk") -Force
}
Write-Host "== done =="
