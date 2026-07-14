import 'package:flutter/services.dart';

/// 定义阅读器系统栏和屏幕常亮平台能力，业务 ViewModel 只通过 Effect 请求。
abstract interface class ReaderPlatformService {
  /// 进入阅读模式，隐藏系统栏并按配置设置屏幕常亮。
  Future<void> enterReader({required bool keepScreenOn});

  /// 阅读中更新屏幕常亮状态。
  Future<void> setKeepScreenOn(bool enabled);

  /// 离开阅读模式，恢复系统栏并取消阅读器设置的常亮状态。
  Future<void> exitReader();
}

/// 使用 Flutter SystemChrome 和最小原生 MethodChannel 实现阅读平台能力。
final class MethodChannelReaderPlatformService implements ReaderPlatformService {
  /// 创建无状态平台服务；原窗口状态由 Android/iOS 宿主桥保存并恢复。
  const MethodChannelReaderPlatformService();

  /// Android MainActivity 与 iOS AppDelegate 共用的通道名称。
  static const MethodChannel _channel = MethodChannel('io.legado.flutter/reader_platform');

  /// 隐藏系统栏并设置屏幕常亮；平台桥缺失时仍保留 Flutter 沉浸模式。
  @override
  Future<void> enterReader({required bool keepScreenOn}) async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await _invokePlatform('enterReader', keepScreenOn);
  }

  /// 更新宿主窗口常亮标志。
  @override
  Future<void> setKeepScreenOn(bool enabled) {
    return _invokePlatform('setKeepScreenOn', enabled);
  }

  /// 取消阅读器常亮并恢复应用统一 edge-to-edge 系统栏模式。
  @override
  Future<void> exitReader() async {
    await _invokePlatform('exitReader', false);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// 调用原生阅读窗口桥；不支持的平台返回受控降级而不终止阅读。
  Future<void> _invokePlatform(String method, bool enabled) async {
    try {
      await _channel.invokeMethod<void>(method, <String, Object?>{
        'enabled': enabled,
      });
    } on MissingPluginException {
      // 宿主尚未更新时仅失去常亮能力，正文阅读和系统栏仍保持可用。
    } on PlatformException {
      // 平台拒绝窗口操作时按系统默认休眠策略降级。
    }
  }
}
