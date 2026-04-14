@echo off
REM ============================================================
REM AIVR - Node :: Check environment health
REM ============================================================

set PATH=D:\env\flutter\bin;D:\env\android\platform-tools;%PATH%
set ANDROID_HOME=D:\env\android

echo.
echo   AIVR - Node :: Environment Check
echo   ========================================
echo.

flutter doctor -v

echo.
echo   Connected devices:
adb devices

echo.
pause
