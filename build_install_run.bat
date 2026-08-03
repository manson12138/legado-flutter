@echo off
setlocal enabledelayedexpansion

rem Flutter project root directory (this script's location), so it works from any cwd.
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

rem Relative path of the release APK produced by Flutter build.
set "APK_PATH=build\app\outputs\flutter-apk\app-release.apk"
set "APP_BUILD_SECRETS=%SCRIPT_DIR%app_build_secrets.json"

rem Android application package name.
set "PACKAGE_NAME=com.contradiction.pagenest"

rem Relative launcher Activity class name.
set "MAIN_ACTIVITY=.MainActivity"

rem Auto-detect the currently connected adb device (first one with state "device").
set "DEVICE_SERIAL="
for /f "tokens=1,2" %%A in ('adb devices') do (
    if "%%B"=="device" if not defined DEVICE_SERIAL set "DEVICE_SERIAL=%%A"
)

if not defined DEVICE_SERIAL (
    echo No connected adb device found. Connect a phone via USB or wireless debugging and check "adb devices".
    exit /b 1
)

echo Detected connected device: %DEVICE_SERIAL%

if not exist "%APP_BUILD_SECRETS%" (
    echo Missing shared build configuration: %APP_BUILD_SECRETS%
    exit /b 1
)

echo Building release APK...
call flutter build apk --release --dart-define-from-file="%APP_BUILD_SECRETS%"
if errorlevel 1 exit /b 1

echo Installing APK to device %DEVICE_SERIAL% (reinstall, keep data)...
adb -s %DEVICE_SERIAL% install -r "%APK_PATH%"
if errorlevel 1 exit /b 1

echo Launching app %PACKAGE_NAME%...
adb -s %DEVICE_SERIAL% shell am start -n %PACKAGE_NAME%/%MAIN_ACTIVITY%

rem Rename the fixed-name build artifact to an archive name with version name/code and build timestamp.
rem Do not rename Gradle's own output: Flutter build looks for the fixed file name app-release.apk
rem when copying the Gradle artifact, so renaming on the Gradle side would break "flutter build apk".

rem Read the version from pubspec.yaml, e.g. "version: 1.2.3+45".
set "PUBSPEC_VERSION="
for /f "tokens=2" %%V in ('findstr /b /r "version:" pubspec.yaml') do (
    if not defined PUBSPEC_VERSION set "PUBSPEC_VERSION=%%V"
)

for /f "tokens=1,2 delims=+" %%X in ("%PUBSPEC_VERSION%") do (
    set "VERSION_NAME=%%X"
    set "VERSION_CODE=%%Y"
)

rem Build a yyyy-MM-dd-HH-mm timestamp without depending on the system locale's date format.
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd-HH-mm'"`) do set "BUILD_TIMESTAMP=%%T"

set "ARCHIVE_PATH=build\app\outputs\flutter-apk\pagenest-release-%VERSION_NAME%-%VERSION_CODE%-%BUILD_TIMESTAMP%.apk"
move /y "%APK_PATH%" "%ARCHIVE_PATH%" >nul
echo Renamed to: %ARCHIVE_PATH%

echo Build, install and launch complete.
endlocal
