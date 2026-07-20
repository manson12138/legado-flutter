#!/usr/bin/env bash

# 任意命令失败时立即退出，并拒绝使用未定义变量或隐藏管道中的失败。
set -euo pipefail

# 脚本所在的 Flutter 工程根目录，确保从任意工作目录执行都能找到工程文件。
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 当前需要安装和启动应用的 Android 手机序列号。
readonly DEVICE_SERIAL="R3CN701H6WL"

# Flutter release 构建生成的 APK 相对路径。
readonly APK_PATH="build/app/outputs/flutter-apk/app-release.apk"

# Flutter Android 应用包名。
readonly PACKAGE_NAME="io.legado.flutter"

# Android 应用启动 Activity 的相对类名。
readonly MAIN_ACTIVITY=".MainActivity"

# 切换到 Flutter 工程根目录，避免调用脚本时的当前目录影响构建和 APK 路径。
cd "${SCRIPT_DIR}"

printf '正在构建 release APK...\n'
flutter build apk --release

printf '正在覆盖安装 APK 到设备 %s...\n' "${DEVICE_SERIAL}"
adb -s "${DEVICE_SERIAL}" install -r "${APK_PATH}"

printf '正在启动应用 %s...\n' "${PACKAGE_NAME}"
adb -s "${DEVICE_SERIAL}" shell am start \
  -n "${PACKAGE_NAME}/${MAIN_ACTIVITY}"

# 把固定命名的构建产物重命名为带版本名、版本号和打包时间戳的归档文件名。
# 不直接改 Gradle 的输出文件名——Flutter 构建流程按固定文件名 app-release.apk 查找
# Gradle 产物再复制，改了 Gradle 侧命名会导致 flutter build apk 找不到产物而失败。
readonly BUILD_TIMESTAMP="$(date '+%Y-%m-%d-%H-%M')"
readonly PUBSPEC_VERSION="$(grep '^version:' pubspec.yaml | head -1 | sed 's/^version:[[:space:]]*//')"
readonly VERSION_NAME="${PUBSPEC_VERSION%%+*}"
readonly VERSION_CODE="${PUBSPEC_VERSION##*+}"
readonly ARCHIVE_PATH="build/app/outputs/flutter-apk/legado-release-${VERSION_NAME}-${VERSION_CODE}-${BUILD_TIMESTAMP}.apk"
mv "${APK_PATH}" "${ARCHIVE_PATH}"
printf '已重命名为：%s\n' "${ARCHIVE_PATH}"

printf '构建、安装和启动已完成。\n'
