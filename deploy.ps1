# AIVR AI Node - Multi-Device Deployment Script (Windows Host)
# Builds and deploys to: 2x Android phones + 1x Windows desktop
#
# Usage:
#   .\deploy.ps1                    # Build all targets
#   .\deploy.ps1 -Android           # Build Android APK only
#   .\deploy.ps1 -Windows           # Build Windows only
#   .\deploy.ps1 -Install           # Build + install to connected Android devices

param(
    [switch]$Android,
    [switch]$Windows,
    [switch]$Install,
    [switch]$All
)

$ErrorActionPreference = "Stop"
$projRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$mobileDir = Join-Path $projRoot ".mobile"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AIVR AI Node - Deployment Builder" -ForegroundColor Cyan
Write-Host "  Target: 2 Android + 1 Windows" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Default to building all if no flags specified
if (-not $Android -and -not $Windows) {
    $All = $true
}

Set-Location $mobileDir

# Ensure dependencies are up to date
Write-Host "[1/4] Resolving dependencies..." -ForegroundColor Yellow
flutter pub get
Write-Host "  Dependencies resolved." -ForegroundColor Green

# --- Android Build ---
if ($Android -or $All) {
    Write-Host ""
    Write-Host "[2/4] Building Android APK (release)..." -ForegroundColor Yellow
    flutter build apk --release

    $apkPath = Join-Path $mobileDir "build\app\outputs\flutter-apk\app-release.apk"
    if (Test-Path $apkPath) {
        $apkSize = [math]::Round((Get-Item $apkPath).Length / 1MB, 1)
        Write-Host "  Android APK built: $apkPath ($apkSize MB)" -ForegroundColor Green

        # Copy APK to project root for easy access
        $deployDir = Join-Path $projRoot "deploy"
        New-Item -ItemType Directory -Force -Path $deployDir | Out-Null
        Copy-Item $apkPath (Join-Path $deployDir "aivr-ai-node.apk") -Force
        Write-Host "  Copied to: deploy\aivr-ai-node.apk" -ForegroundColor Green
    } else {
        Write-Host "  ERROR: APK not found at expected path" -ForegroundColor Red
        exit 1
    }

    # Install to connected Android devices if requested
    if ($Install) {
        Write-Host ""
        Write-Host "[2b] Installing to connected Android devices..." -ForegroundColor Yellow
        $devices = adb devices | Select-String -Pattern "^\S+\s+device$"
        $deviceCount = ($devices | Measure-Object).Count

        if ($deviceCount -eq 0) {
            Write-Host "  WARNING: No Android devices connected via USB" -ForegroundColor Yellow
            Write-Host "  Connect phones via USB with USB Debugging enabled" -ForegroundColor Yellow
        } else {
            Write-Host "  Found $deviceCount device(s)" -ForegroundColor Green
            foreach ($device in $devices) {
                $serial = ($device -split "\s+")[0]
                Write-Host "  Installing to $serial..." -ForegroundColor Cyan
                adb -s $serial install -r $apkPath
                Write-Host "  Installed on $serial" -ForegroundColor Green
            }
        }
    }
} else {
    Write-Host "[2/4] Skipping Android build" -ForegroundColor DarkGray
}

# --- Windows Build ---
if ($Windows -or $All) {
    Write-Host ""
    Write-Host "[3/4] Building Windows desktop (release)..." -ForegroundColor Yellow
    flutter build windows --release

    $winBuildDir = Join-Path $mobileDir "build\windows\x64\runner\Release"
    if (Test-Path $winBuildDir) {
        Write-Host "  Windows build complete: $winBuildDir" -ForegroundColor Green

        # Copy to deploy folder
        $deployDir = Join-Path $projRoot "deploy\windows"
        if (Test-Path $deployDir) { Remove-Item $deployDir -Recurse -Force }
        Copy-Item $winBuildDir $deployDir -Recurse -Force
        Write-Host "  Copied to: deploy\windows\" -ForegroundColor Green
    } else {
        Write-Host "  ERROR: Windows build output not found" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[3/4] Skipping Windows build" -ForegroundColor DarkGray
}

# --- Summary ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Deployment artifacts:" -ForegroundColor White

$deployDir = Join-Path $projRoot "deploy"
if (Test-Path (Join-Path $deployDir "aivr-ai-node.apk")) {
    Write-Host "  Android APK:  deploy\aivr-ai-node.apk" -ForegroundColor Green
    Write-Host "    -> Install on Phone 1 and Phone 2" -ForegroundColor DarkGray
}
if (Test-Path (Join-Path $deployDir "windows")) {
    Write-Host "  Windows App:  deploy\windows\cactus_openai_server.exe" -ForegroundColor Green
    Write-Host "    -> Run on Windows PC" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Install APK on both Android phones" -ForegroundColor White
Write-Host "  2. Run the Windows app on your PC" -ForegroundColor White
Write-Host "  3. Connect all devices to the same WiFi" -ForegroundColor White
Write-Host "  4. Open the SWARM tab - devices auto-discover each other" -ForegroundColor White
Write-Host "  5. Start the server on each device" -ForegroundColor White
Write-Host ""

Set-Location $projRoot
