import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 把 Dart 日志写入 Android 原生 Logcat Tag，并为非 Android 平台提供控制台回退。
final class AndroidLogWriter {
  /// 创建无状态 Android 日志写入器。
  const AndroidLogWriter();

  /// 与 Android MainActivity 注册名称一致的平台通道。
  static const MethodChannel _channel = MethodChannel(
    'io.legado.flutter/logging',
  );

  /// 将已经分段的单条日志交给 Android 原生输出。
  void write({
    required AppLogLevel level,
    required String tag,
    required String message,
  }) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('[$tag][${level.name.toUpperCase()}] $message');
      return;
    }
    unawaited(
      _channel
          .invokeMethod<void>(
            'log',
            <String, Object?>{
              'level': level.name,
              'tag': tag,
              'message': message,
            },
          )
          .catchError((Object error) {
            /// 平台通道暂不可用时仍向 Flutter 控制台输出，避免日志静默丢失。
            debugPrint('[$tag][${level.name.toUpperCase()}] $message');
          }),
    );
  }
}
