import 'dart:convert';
import 'dart:io';

/// 将统一构建配置中的 HMAC 参数编码为 Flutter iOS 构建所需的 DART_DEFINES 值。
void main(List<String> arguments) {
  /// 仅接收唯一的构建配置文件路径，避免 Xcode 构建时使用不明确的配置来源。
  if (arguments.length != 1) {
    stderr.writeln('缺少 app_build_secrets.json 路径。');
    exitCode = 64;
    return;
  }
  /// 构建配置文件由 Android 与 iOS 共用，密钥只在内存中完成编码。
  final File configFile = File(arguments.single);
  if (!configFile.existsSync()) {
    stderr.writeln('缺少 app_build_secrets.json。');
    exitCode = 66;
    return;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(configFile.readAsStringSync());
  } on Object {
    stderr.writeln('app_build_secrets.json 不是有效 JSON。');
    exitCode = 65;
    return;
  }
  if (decoded is! Map<Object?, Object?>) {
    stderr.writeln('app_build_secrets.json 必须是 JSON 对象。');
    exitCode = 65;
    return;
  }
  /// 空密钥会覆盖 Dart 开发默认值且必然导致服务端验签失败，因此直接中止构建。
  final Object? rawSecret = decoded['REMOTE_APP_HMAC_SECRET'];
  if (rawSecret is! String || rawSecret.trim().isEmpty) {
    stderr.writeln('REMOTE_APP_HMAC_SECRET 必须是非空字符串。');
    exitCode = 65;
    return;
  }
  /// Flutter 的 iOS 构建链路使用 Base64 编码、逗号分隔的 DART_DEFINES。
  stdout.write(
    base64.encode(
      utf8.encode('REMOTE_APP_HMAC_SECRET=$rawSecret'),
    ),
  );
}
