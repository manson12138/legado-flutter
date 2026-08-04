import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android APK 下载、完整性校验和系统安装器交接阶段。
enum AndroidApkUpdateStage {
  /// 尚未开始或上一次流程已重置。
  idle,
  /// 正在从服务端下载或断点续传 APK。
  downloading,
  /// 正在校验文件大小和 SHA-256。
  verifying,
  /// APK 已就绪，正在打开 Android 系统安装器。
  installing,
  /// 需要用户先允许当前 App 安装未知来源应用。
  permissionRequired,
  /// 原生流程返回受控失败。
  failed,
}

/// APK 更新流程向界面公开的只读状态。
final class AndroidApkUpdateState {
  /// 创建 APK 更新状态。
  const AndroidApkUpdateState({
    this.stage = AndroidApkUpdateStage.idle,
    this.downloadedBytes = 0,
    this.totalBytes,
    this.message,
  });

  /// 当前流程阶段。
  final AndroidApkUpdateStage stage;
  /// 当前已写入临时文件的字节数。
  final int downloadedBytes;
  /// 服务端约定的完整 APK 字节数。
  final int? totalBytes;
  /// 可安全展示的原生受控文案。
  final String? message;

  /// 下载任务运行期间禁止重复点击。
  bool get isBusy =>
      stage == AndroidApkUpdateStage.downloading ||
      stage == AndroidApkUpdateStage.verifying;

  /// 有完整进度信息时返回 0 到 1 的比例。
  double? get progress {
    final int? total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (downloadedBytes / total).clamp(0, 1).toDouble();
  }
}

/// 通过窄平台通道调用 Android 原生 APK 更新器。
final class AndroidApkUpdateService {
  /// 创建并注册原生进度回调。
  AndroidApkUpdateService() {
    _channel.setMethodCallHandler(_handleNativeState);
  }

  /// 与 Android `AppUpdateBridge` 共用的通道。
  static const MethodChannel _channel = MethodChannel(
    'io.legado.flutter/app_update',
  );

  /// 供升级覆盖层订阅的当前状态。
  final ValueNotifier<AndroidApkUpdateState> state =
      ValueNotifier<AndroidApkUpdateState>(const AndroidApkUpdateState());

  /// 下载或续传 APK，校验通过后打开系统安装器。
  Future<void> downloadAndInstall({
    required String url,
    required String sha256,
    required int byteSize,
    required String versionName,
  }) async {
    if (state.value.isBusy) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('downloadAndInstall', <String, Object?>{
        'url': url,
        'sha256': sha256,
        'byteSize': byteSize,
        'versionName': versionName,
      });
    } on PlatformException catch (error) {
      state.value = AndroidApkUpdateState(
        stage: AndroidApkUpdateStage.failed,
        message: error.message ?? '无法启动 APK 更新，请稍后重试',
      );
    } on MissingPluginException {
      state.value = const AndroidApkUpdateState(
        stage: AndroidApkUpdateStage.failed,
        message: '当前安装包不支持应用内更新，请重新安装最新版本',
      );
    }
  }

  /// 接收原生线程经主线程发布的受控进度，不接收路径、URL 或摘要。
  Future<void> _handleNativeState(MethodCall call) async {
    if (call.method != 'updateState' ||
        call.arguments is! Map<Object?, Object?>) {
      return;
    }
    final Map<Object?, Object?> arguments =
        call.arguments as Map<Object?, Object?>;
    final String stageName = arguments['stage'] is String
        ? arguments['stage'] as String
        : 'failed';
    final AndroidApkUpdateStage stage = switch (stageName) {
      'downloading' => AndroidApkUpdateStage.downloading,
      'verifying' => AndroidApkUpdateStage.verifying,
      'installing' => AndroidApkUpdateStage.installing,
      'permissionRequired' => AndroidApkUpdateStage.permissionRequired,
      _ => AndroidApkUpdateStage.failed,
    };
    state.value = AndroidApkUpdateState(
      stage: stage,
      downloadedBytes: arguments['downloadedBytes'] is num
          ? (arguments['downloadedBytes'] as num).toInt()
          : 0,
      totalBytes: arguments['totalBytes'] is num
          ? (arguments['totalBytes'] as num).toInt()
          : null,
      message: arguments['message'] is String
          ? arguments['message'] as String
          : null,
    );
  }

  /// 解除平台回调并释放通知器。
  void dispose() {
    _channel.setMethodCallHandler(null);
    state.dispose();
  }
}
