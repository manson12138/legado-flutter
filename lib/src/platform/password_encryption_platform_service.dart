import 'package:flutter/services.dart';

/// 密码加密原生通道名称；Android 与 iOS 必须保持一致。
const String passwordEncryptionPlatformChannel = 'com.contradiction.pagenest/password_encryption';

/// 将登录密码转换为服务端约定密文的受控平台能力。
abstract interface class PasswordEncryptionService {
  /// 使用 RSA-OAEP-SHA256 加密 UTF-8 密码并返回 Base64 密文。
  Future<String> encryptRsaOaepSha256({required String publicKeyPem, required String password});
}

/// 通过系统密码学实现 RSA-OAEP-SHA256，避免 Dart 层持有密钥解析或密码学实现细节。
final class MethodChannelPasswordEncryptionService implements PasswordEncryptionService {
  /// 创建使用固定原生通道的密码加密服务。
  const MethodChannelPasswordEncryptionService({MethodChannel channel = const MethodChannel(passwordEncryptionPlatformChannel)}) : _channel = channel;

  /// 原生加密能力通道。
  final MethodChannel _channel;

  @override
  Future<String> encryptRsaOaepSha256({required String publicKeyPem, required String password}) async {
    final String normalizedPublicKey = publicKeyPem.trim();
    if (normalizedPublicKey.isEmpty || password.isEmpty) {
      throw const FormatException('密码安全处理失败，请重试');
    }
    try {
      final String? encrypted = await _channel.invokeMethod<String>(
        'encryptRsaOaepSha256',
        <String, Object>{'publicKeyPem': normalizedPublicKey, 'plaintext': password},
      );
      if (encrypted == null || encrypted.isEmpty) {
        throw const FormatException('密码安全处理失败，请重试');
      }
      return encrypted;
    } on PlatformException {
      throw const FormatException('密码安全处理失败，请重试');
    } on MissingPluginException {
      throw const FormatException('密码安全处理失败，请重试');
    }
  }
}
