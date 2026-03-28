@echo off
REM ============================================================
REM AIVR - Node :: One-time environment setup for Windows
REM Run this ONCE as Administrator to install Flutter + Android SDK
REM ============================================================

echo.
echo   ========================================
echo   AIVR - Node Environment Setup
echo   ========================================
echo.

REM -- Create env directory --
if not exist "D:\env" mkdir "D:\env"

REM -- Install Flutter SDK --
echo [1/4] Installing Flutter SDK...
if exist "D:\env\flutter\bin\flutter.bat" (
    echo   Flutter already installed, skipping.
) else (
    echo   Cloning Flutter stable branch...
    git clone https://github.com/flutter/flutter.git -b stable "D:\env\flutter"
    if errorlevel 1 (
        echo   ERROR: Failed to clone Flutter. Make sure git is installed.
        pause
        exit /b 1
    )
)

REM -- Install Android command-line tools --
echo [2/4] Installing Android SDK...
if not exist "D:\env\android" mkdir "D:\env\android"
if not exist "D:\env\android\cmdline-tools" (
    echo   Downloading Android command-line tools...
    powershell -Command "Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' -OutFile 'D:\env\android-tools.zip'"
    echo   Extracting...
    powershell -Command "Expand-Archive -Path 'D:\env\android-tools.zip' -DestinationPath 'D:\env\android\cmdline-tools-temp' -Force"
    if not exist "D:\env\android\cmdline-tools\latest" mkdir "D:\env\android\cmdline-tools\latest"
    xcopy /E /Y "D:\env\android\cmdline-tools-temp\cmdline-tools\*" "D:\env\android\cmdline-tools\latest\"
    rmdir /S /Q "D:\env\android\cmdline-tools-temp"
    del "D:\env\android-tools.zip"
) else (
    echo   Android cmdline-tools already installed, skipping.
)

REM -- Install required Android SDK packages --
echo [3/4] Installing Android SDK packages (build-tools, platform-tools)...
set ANDROID_HOME=D:\env\android
set PATH=%ANDROID_HOME%\cmdline-tools\latest\bin;%ANDROID_HOME%\platform-tools;%PATH%

echo y | sdkmanager --sdk_root="%ANDROID_HOME%" "platform-tools" "build-tools;34.0.0" "platforms;android-34"

REM -- Accept all licenses --
echo [4/4] Accepting Android licenses...
echo y | sdkmanager --sdk_root="%ANDROID_HOME%" --licenses

REM -- Set environment variables permanently --
echo.
echo   Setting environment variables...
setx ANDROID_HOME "D:\env\android" /M 2>nul
setx FLUTTER_ROOT "D:\env\flutter" /M 2>nul

REM -- Add to system PATH --
powershell -Command "[Environment]::SetEnvironmentVariable('PATH', [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';D:\env\flutter\bin;D:\env\android\platform-tools', 'Machine')"

echo.
echo   ========================================
echo   Setup complete!
echo   ========================================
echo.
echo   Close this terminal and open a new one,
echo   then run:  flutter doctor
echo.
echo   To build the app:
echo     cd D:\AIVR\AIVR-Ai-Node-Mobile\.mobile
echo     flutter pub get
echo     flutter run --release
echo.
pause
