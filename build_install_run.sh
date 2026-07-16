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

printf '构建、安装和启动已完成。\n'
