@echo off
REM ============================================================
REM AIVR - Node :: Build and install APK
REM ============================================================

set PATH=D:\env\flutter\bin;D:\env\android\platform-tools;%PATH%
set ANDROID_HOME=D:\env\android

cd /d "%~dp0.mobile"

echo.
echo   AIVR - Node :: Build
echo   ========================================
echo.

echo [1/3] Getting dependencies...
call flutter pub get
if errorlevel 1 (
    echo ERROR: flutter pub get failed
    pause
    exit /b 1
)

echo.
echo [2/3] Building release APK...
call flutter build apk --release
if errorlevel 1 (
    echo ERROR: Build failed
    pause
    exit /b 1
)

echo.
echo [3/3] Installing on device...
adb devices
echo.
call flutter install
if errorlevel 1 (
    echo.
    echo   APK built but install failed.
    echo   APK location: build\app\outputs\flutter-apk\app-release.apk
    echo   Manually install: adb install build\app\outputs\flutter-apk\app-release.apk
)

echo.
echo   ========================================
echo   Done! Check your phone.
echo   ========================================
echo.
pause
