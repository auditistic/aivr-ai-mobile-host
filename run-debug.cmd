@echo off
REM ============================================================
REM AIVR - Node :: Run in debug mode (hot reload)
REM ============================================================

set PATH=D:\env\flutter\bin;D:\env\android\platform-tools;%PATH%
set ANDROID_HOME=D:\env\android

cd /d "%~dp0.mobile"

echo.
echo   AIVR - Node :: Debug Mode (hot reload)
echo   ========================================
echo.

call flutter pub get
call flutter run --debug

pause
