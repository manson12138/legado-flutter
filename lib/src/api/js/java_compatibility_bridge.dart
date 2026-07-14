import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'js_engine.dart';

/// Java/Rhino 白名单调用桥。
///
/// 只实现固定、跨平台且有 Android 调用证据的方法；未知类或方法必须抛出可诊断错误。
final class JavaCompatibilityBridge {
  /// 创建无状态 Java 兼容桥。
  const JavaCompatibilityBridge();

  /// 调用 Legado `java` helper 中可纯 Dart 实现的方法。
  Object? invokeHelper(String method, List<Object?> arguments) {
    return switch (method) {
      'md5Encode' => _md5(_stringArgument(arguments, 0, method)),
      'md5Encode16' => _md5(_stringArgument(arguments, 0, method)).substring(8, 24),
      'base64Encode' => base64Encode(utf8.encode(_stringArgument(arguments, 0, method))),
      'base64Decode' => utf8.decode(
        base64Decode(_stringArgument(arguments, 0, method)),
        allowMalformed: false,
      ),
      'hexDecodeToString' => utf8.decode(
        _hexDecode(_stringArgument(arguments, 0, method)),
        allowMalformed: false,
      ),
      'hexEncode' => _hexEncode(utf8.encode(_stringArgument(arguments, 0, method))),
      'encodeURI' => Uri.encodeFull(_stringArgument(arguments, 0, method)),
      'encodeURIComponent' => Uri.encodeComponent(_stringArgument(arguments, 0, method)),
      'decodeURI' => Uri.decodeFull(_stringArgument(arguments, 0, method)),
      'decodeURIComponent' => Uri.decodeComponent(_stringArgument(arguments, 0, method)),
      'randomUUID' => _randomUuid(),
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持 Legado java.$method',
      ),
    };
  }

  /// 调用 `Java.type` 白名单类的静态方法。
  Object? invokeClass(String className, String method, List<Object?> arguments) {
    if (className == 'java.net.URLEncoder' && method == 'encode') {
      return Uri.encodeQueryComponent(_stringArgument(arguments, 0, '$className.$method'));
    }
    if (className == 'android.util.Base64') {
      if (method == 'encodeToString') {
        return base64Encode(_byteArguments(arguments, 0, '$className.$method'));
      }
      if (method == 'decode') {
        return base64Decode(_stringArgument(arguments, 0, '$className.$method'));
      }
    }
    throw JsEngineException(
      kind: JsFailureKind.unsupportedApi,
      message: '未支持 Java/Rhino 调用 $className.$method',
    );
  }

  /// 计算 UTF-8 文本 MD5。
  String _md5(String value) {
    return md5.convert(utf8.encode(value)).toString();
  }

  /// 读取必需字符串参数。
  String _stringArgument(List<Object?> arguments, int index, String method) {
    if (index >= arguments.length) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: '$method 缺少第 ${index + 1} 个参数',
      );
    }
    return arguments[index]?.toString() ?? '';
  }

  /// 读取字节参数，兼容 Uint8List 与数值列表。
  List<int> _byteArguments(List<Object?> arguments, int index, String method) {
    if (index >= arguments.length) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: '$method 缺少第 ${index + 1} 个参数',
      );
    }
    /// 原始字节参数。
    final Object? value = arguments[index];
    if (value is List) {
      return value.map<int>((Object? item) {
        if (item is num) {
          return item.toInt() & 0xFF;
        }
        throw JsEngineException(
          kind: JsFailureKind.bridge,
          message: '$method 的字节列表包含非数值项',
        );
      }).toList(growable: false);
    }
    throw JsEngineException(
      kind: JsFailureKind.bridge,
      message: '$method 需要字节列表参数',
    );
  }

  /// 解码十六进制文本。
  List<int> _hexDecode(String value) {
    /// 去除空白后的十六进制文本。
    final String normalized = value.replaceAll(RegExp(r'\s+'), '');
    if (normalized.length.isOdd) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: '十六进制文本长度必须为偶数',
      );
    }
    /// 字节结果。
    final List<int> result = <int>[];
    for (int index = 0; index < normalized.length; index += 2) {
      /// 当前字节。
      final int? byte = int.tryParse(normalized.substring(index, index + 2), radix: 16);
      if (byte == null) {
        throw const JsEngineException(
          kind: JsFailureKind.bridge,
          message: '十六进制文本包含无效字符',
        );
      }
      result.add(byte);
    }
    return result;
  }

  /// 编码字节为小写十六进制文本。
  String _hexEncode(List<int> bytes) {
    return bytes.map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 使用安全随机数生成 RFC 4122 v4 UUID。
  String _randomUuid() {
    /// 安全随机源。
    final Random random = Random.secure();
    /// 16 字节 UUID。
    final List<int> bytes = List<int>.generate(16, (int index) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    /// 十六进制 UUID。
    final String value = _hexEncode(bytes);
    return '${value.substring(0, 8)}-'
        '${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-'
        '${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }
}
