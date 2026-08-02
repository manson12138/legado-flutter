import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/model/local_book.dart';

/// 保存 Android/iOS 外部“打开方式”入口生成的一次性本地书候选。
final class ExternalLocalBookOpenRequest {
  /// 创建等待导入确认的外部文件请求。
  const ExternalLocalBookOpenRequest({
    required this.file,
    required this.cleanupToken,
  });

  /// 原生层已经复制到应用 cache、可立即交给现有导入器读取的文件。
  final LocalBookPickedFile file;

  /// 原生层生成的随机清理 token，不包含绝对路径。
  final String cleanupToken;
}

/// Android/iOS 外部本地书入口出现受控失败时抛出的平台边界错误。
final class ExternalLocalBookOpenException implements Exception {
  /// 创建不包含文件路径和正文的安全错误。
  const ExternalLocalBookOpenException(this.message);

  /// 可直接展示给用户的中文提示。
  final String message;

  @override
  String toString() => message;
}

/// 定义外部文件打开事件、消费和临时副本释放边界。
abstract interface class ExternalLocalBookOpenService {
  /// 原生层通知存在待消费请求时发出的轻量事件。
  Stream<void> get requests;

  /// 消费并复制下一项外部 TXT；没有待处理请求时返回空。
  Future<ExternalLocalBookOpenRequest?> consumeNext();

  /// 释放已经导入、失败或取消的一次性原生临时副本。
  Future<void> releaseTemporary(String cleanupToken);

  /// 解除平台回调并关闭事件流。
  Future<void> dispose();
}

/// 使用 MethodChannel 连接 Android/iOS `ExternalTxtOpenBridge`。
///
/// Android 从 `ACTION_VIEW` 接收 URI，iOS 从 Scene URL Context 接收安全作用域文件；
/// 两端都先生成有界 cache 临时副本，再复用同一 Dart 导入确认与清理链路。
final class DefaultExternalLocalBookOpenService
    implements ExternalLocalBookOpenService {
  /// 创建应用生命周期内唯一外部本地书入口服务。
  DefaultExternalLocalBookOpenService() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// 与 Android 宿主共用的稳定通道。
  static const MethodChannel _channel = MethodChannel(
    'io.legado.flutter/external_txt_open',
  );

  /// 把热启动通知广播给应用组合根，不承载文件内容。
  final StreamController<void> _requestController =
      StreamController<void>.broadcast(sync: true);

  /// 是否已经释放，避免原生晚到通知写入关闭流。
  bool _disposed = false;

  @override
  Stream<void> get requests => _requestController.stream;

  /// 接收 Android `onNewIntent` 或 iOS Scene 热启动后的轻量可用通知。
  Future<void> _handleNativeCall(MethodCall call) async {
    if (_disposed || call.method != 'externalTxtOpenAvailable') {
      return;
    }
    _requestController.add(null);
  }

  /// 请求原生层在后台流式复制下一 TXT，并把结果转换为项目领域文件描述。
  @override
  Future<ExternalLocalBookOpenRequest?> consumeNext() async {
    if (_disposed) {
      return null;
    }
    try {
      /// 原生返回的一次性临时文件事实。
      final Map<Object?, Object?>? payload =
          await _channel.invokeMapMethod<Object?, Object?>('consumeNext');
      if (payload == null) {
        return null;
      }
      /// 应用 cache 中可立即读取的临时绝对路径。
      final Object? rawPath = payload['path'];
      /// 外部提供方给出的安全显示名。
      final Object? rawName = payload['name'];
      /// 复制完成后的真实字节数。
      final Object? rawSize = payload['size'];
      /// 释放临时副本使用的随机 token。
      final Object? rawToken = payload['token'];
      if (rawPath is! String ||
          rawPath.isEmpty ||
          rawName is! String ||
          rawName.isEmpty ||
          rawSize is! num ||
          rawSize <= 0 ||
          rawToken is! String ||
          rawToken.isEmpty) {
        throw const ExternalLocalBookOpenException(
          '系统返回的外部 TXT 文件信息不完整，请重新打开该文件',
        );
      }
      return ExternalLocalBookOpenRequest(
        file: LocalBookPickedFile(
          path: rawPath,
          name: rawName,
          size: rawSize.toInt(),
        ),
        cleanupToken: rawToken,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      /// 平台错误消息只在非空时展示，避免使用强制空值断言。
      final String platformMessage = error.message?.trim() ?? '';
      throw ExternalLocalBookOpenException(
        platformMessage.isNotEmpty
            ? platformMessage
            : '无法读取外部 TXT 文件，请重新打开该文件',
      );
    }
  }

  /// 只把随机 token 交回原生层，Dart 不直接删除任意绝对路径。
  @override
  Future<void> releaseTemporary(String cleanupToken) async {
    if (_disposed || cleanupToken.isEmpty) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(
        'releaseTemporary',
        <String, Object?>{'token': cleanupToken},
      );
    } on MissingPluginException {
      // 未接入宿主桥的平台没有生成临时副本，无需执行清理。
    } on PlatformException {
      // cache 临时文件仍会由 Android/iOS 宿主在下次启动时按过期时间清理。
    }
  }

  /// 解除平台处理器并关闭广播流。
  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await _requestController.close();
  }
}
