@echo off
rem Build release APK only (no install, no run). On success, rename the
rem output to legado-<type>-<versionName>-<versionCode>-<timestamp>.apk and
rem open its folder in Explorer with the file selected.
rem
rem The rename happens AFTER the Flutter build, not via Gradle's own output
rem file name: Flutter's build pipeline looks for a fixed file name
rem (app-release.apk) inside the Gradle output directory and copies it into
rem build/app/outputs/flutter-apk/; renaming the Gradle-side output would make
rem Flutter unable to find it and fail the build.
setlocal enabledelayedexpansion

set "BUILD_TYPE=release"

rem Flutter project root, so double-clicking from anywhere still works.
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

rem Relative path of the APK produced by a Flutter release build.
set "APK_PATH=build\app\outputs\flutter-apk\app-%BUILD_TYPE%.apk"
set "APK_FULL_PATH=%SCRIPT_DIR%%APK_PATH%"

echo Building %BUILD_TYPE% APK...
call flutter build apk --%BUILD_TYPE%
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

rem Parse version name and version code from pubspec.yaml (version: 1.0.0+2).
set "RAW_VERSION="
for /f "tokens=1,* delims=:" %%A in ('findstr /b "version:" pubspec.yaml') do set "RAW_VERSION=%%B"
set "RAW_VERSION=%RAW_VERSION: =%"
for /f "tokens=1,2 delims=+" %%A in ("%RAW_VERSION%") do (
    set "VERSION_NAME=%%A"
    set "VERSION_CODE=%%B"
)

rem Build timestamp via PowerShell for a locale-independent yyyy-MM-dd-HH-mm format.
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd-HH-mm'"') do set "BUILD_TIMESTAMP=%%T"

set "ARCHIVE_NAME=legado-%BUILD_TYPE%-%VERSION_NAME%-%VERSION_CODE%-%BUILD_TIMESTAMP%.apk"
set "ARCHIVE_FULL_PATH=%SCRIPT_DIR%build\app\outputs\flutter-apk\%ARCHIVE_NAME%"
move /Y "%APK_FULL_PATH%" "%ARCHIVE_FULL_PATH%" >nul

echo.
echo Build succeeded. APK saved at:
echo %ARCHIVE_FULL_PATH%

rem Open Explorer with the renamed APK selected.
explorer.exe /select,"%ARCHIVE_FULL_PATH%"

pause
endlocal
