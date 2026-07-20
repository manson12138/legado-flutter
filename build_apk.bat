@echo off
rem Build release APK only (no install, no run). On success, print the APK
rem path and open its folder in Explorer with the file selected.
setlocal

rem Flutter project root, so double-clicking from anywhere still works.
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

rem Relative path of the APK produced by a Flutter release build.
set "APK_PATH=build\app\outputs\flutter-apk\app-release.apk"
set "APK_FULL_PATH=%SCRIPT_DIR%%APK_PATH%"

echo Building release APK...
call flutter build apk --release
if errorlevel 1 (
    echo.
    echo Build failed. See the errors above.
    pause
    exit /b 1
)

if not exist "%APK_FULL_PATH%" (
    echo.
    echo Build command finished but the APK was not found at:
    echo %APK_FULL_PATH%
    pause
    exit /b 1
)

echo.
echo Build succeeded. APK saved at:
echo %APK_FULL_PATH%

rem Open Explorer with the generated APK selected.
explorer.exe /select,"%APK_FULL_PATH%"

pause
endlocal
