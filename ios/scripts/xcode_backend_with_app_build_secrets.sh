#!/usr/bin/env bash

# 在 Xcode 单击 Run 时读取统一构建配置，并委托 Flutter 原始 xcode_backend 执行构建。
set -euo pipefail

# 当前脚本位于 ios/scripts，统一配置文件位于 Flutter 项目根目录。
readonly IOS_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIRECTORY="$(cd -- "${IOS_DIRECTORY}/.." && pwd)"
readonly SECRETS_FILE="${PROJECT_DIRECTORY}/app_build_secrets.json"
readonly DART_EXECUTABLE="${FLUTTER_ROOT:?FLUTTER_ROOT 未定义}/bin/cache/dart-sdk/bin/dart"
readonly ENCODER_SCRIPT="${PROJECT_DIRECTORY}/tool/encode_app_build_secrets.dart"

# 编码过程只向 Flutter 传递 DART_DEFINES，绝不回显密钥原文。
readonly APP_HMAC_DEFINE="$("${DART_EXECUTABLE}" "${ENCODER_SCRIPT}" "${SECRETS_FILE}")"
export DART_DEFINES="${DART_DEFINES:+${DART_DEFINES},}${APP_HMAC_DEFINE}"

exec /bin/sh "${FLUTTER_ROOT}/packages/flutter_tools/bin/xcode_backend.sh" "$@"
