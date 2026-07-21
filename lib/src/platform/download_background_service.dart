import 'package:flutter/services.dart';

/// 下载后台保活平台边界：Android 使用前台服务，iOS 只申请系统允许的有限后台执行时间。
abstract interface class DownloadBackgroundService {
  /// 开始或更新后台下载状态与平台通知摘要。
  Future<void> startOrUpdate({
    required int waitingCount,
    required int runningCount,
    required int pausedCount,
    required int successCount,
    required int failedCount,
  });

  /// 队列不再需要后台执行时结束平台保活。
  Future<void> stop();
}

/// 通过 Android/iOS MethodChannel 控制下载后台能力。
final class MethodChannelDownloadBackgroundService
    implements DownloadBackgroundService {
  /// 创建无状态下载后台平台服务。
  const MethodChannelDownloadBackgroundService();

  /// 与 Android 前台服务和 iOS 有限后台任务共用的通道。
  static const MethodChannel _channel = MethodChannel(
    'io.legado.flutter/download_background',
  );

  /// 把可公开的任务计数发送给平台，不传书名、书源 URL 或正文。
  @override
  Future<void> startOrUpdate({
    required int waitingCount,
    required int runningCount,
    required int pausedCount,
    required int successCount,
    required int failedCount,
  }) async {
    await _channel.invokeMethod<void>('startOrUpdate', <String, Object?>{
      'waitingCount': waitingCount,
      'runningCount': runningCount,
      'pausedCount': pausedCount,
      'successCount': successCount,
      'failedCount': failedCount,
    });
  }

  /// 通知平台结束前台服务或有限后台任务。
  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }
}
