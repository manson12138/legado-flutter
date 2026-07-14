import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../help/logging/app_logger.dart';

/// 连接相机扫码插件、重复结果隔离和路由返回值的书源二维码页面。
final class BookSourceQrScannerRoute extends StatefulWidget {
  /// 创建只识别二维码文本的书源扫描路由。
  const BookSourceQrScannerRoute({required this.logger, super.key});

  /// 【扫码诊断日志】不记录二维码正文和书源地址的应用日志边界。
  final AppLogger logger;

  /// 创建扫码页面状态。
  @override
  State<BookSourceQrScannerRoute> createState() => _BookSourceQrScannerRouteState();
}

/// 管理相机控制器和一次性有效结果，书源 JSON 解析仍由原 ViewModel 负责。
final class _BookSourceQrScannerRouteState extends State<BookSourceQrScannerRoute>
    with WidgetsBindingObserver {
  /// 单次二维码允许返回的最大 UTF-8 字节数，拒绝异常超大外部输入。
  static const int maxQrTextBytes = 64 * 1024;

  /// 页面生命周期内唯一扫码控制器，只启用二维码格式。
  final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// 是否已经消费一个有效结果，防止同一帧多码或连续帧重复返回。
  bool _resultHandled = false;

  /// 【扫码诊断日志】上一次已记录的相机运行状态，用于避免监听器重复输出。
  bool? _lastLoggedRunning;

  /// 【扫码诊断日志】上一次已记录的相机初始化状态，用于避免监听器重复输出。
  bool? _lastLoggedStarting;

  /// 【扫码诊断日志】上一次已记录的插件错误码，用于避免 build 重绘产生重复错误。
  MobileScannerErrorCode? _lastLoggedErrorCode;

  /// 注册应用生命周期观察，并在扫码组件完成挂载后启动相机。
  @override
  void initState() {
    super.initState();
    // 【扫码诊断日志】扫码页面生命周期起点。
    widget.logger.info(message: '$bookSourceQrScanLogTag stage=scanner_route_initialized');
    _controller.addListener(_handleControllerStateChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (mounted) {
        widget.logger.debug(
          message: '$bookSourceQrScanLogTag stage=scanner_first_frame_ready',
        );
        unawaited(_startScanner());
      }
    });
  }

  /// 【扫码诊断日志】记录去重后的 controller 状态与插件错误分类。
  void _handleControllerStateChanged() {
    /// 当前相机控制器状态快照。
    final MobileScannerState scannerState = _controller.value;
    if (_lastLoggedStarting != scannerState.isStarting ||
        _lastLoggedRunning != scannerState.isRunning) {
      _lastLoggedStarting = scannerState.isStarting;
      _lastLoggedRunning = scannerState.isRunning;
      widget.logger.debug(
        message:
            '$bookSourceQrScanLogTag stage=controller_state initialized=${scannerState.isInitialized} starting=${scannerState.isStarting} running=${scannerState.isRunning} permission=${scannerState.hasCameraPermission}',
      );
    }
    /// 当前插件错误；为空表示 controller 没有报告错误。
    final MobileScannerException? scannerError = scannerState.error;
    if (scannerError == null) {
      _lastLoggedErrorCode = null;
      return;
    }
    if (_lastLoggedErrorCode == scannerError.errorCode) {
      return;
    }
    _lastLoggedErrorCode = scannerError.errorCode;
    widget.logger.error(
      message:
          '$bookSourceQrScanLogTag stage=controller_error code=${scannerError.errorCode.name} platformCode=${scannerError.errorDetails?.code ?? 'none'}',
      error: scannerError,
    );
  }

  /// 按插件状态防止重复启动或初始化中的并发启动。
  Future<void> _startScanner() async {
    /// 当前相机控制器状态。
    final MobileScannerState scannerState = _controller.value;
    if (_resultHandled || scannerState.isRunning || scannerState.isStarting) {
      widget.logger.debug(
        message:
            '$bookSourceQrScanLogTag stage=scanner_start_skipped handled=$_resultHandled running=${scannerState.isRunning} starting=${scannerState.isStarting}',
      );
      return;
    }
    widget.logger.info(message: '$bookSourceQrScanLogTag stage=scanner_start_requested');
    try {
      await _controller.start();
      /// 相机启动调用完成后的状态快照。
      final MobileScannerState completedState = _controller.value;
      widget.logger.info(
        message:
            '$bookSourceQrScanLogTag stage=scanner_start_finished running=${completedState.isRunning} permission=${completedState.hasCameraPermission} error=${completedState.error?.errorCode.name ?? 'none'}',
      );
    } on MobileScannerException catch (error) {
      // 【扫码诊断日志】插件通常写入 controller 状态，此分支覆盖直接抛出的控制器异常。
      widget.logger.error(
        message:
            '$bookSourceQrScanLogTag stage=scanner_start_threw code=${error.errorCode.name}',
        error: error,
      );
    } catch (error, stackTrace) {
      widget.logger.error(
        message: '$bookSourceQrScanLogTag stage=scanner_start_failed_unexpectedly',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 接收插件检测结果并返回首个非空、大小合法的二维码文本。
  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_resultHandled) {
      widget.logger.debug(
        message: '$bookSourceQrScanLogTag stage=detection_ignored reason=result_handled',
      );
      return;
    }
    widget.logger.debug(
      message:
          '$bookSourceQrScanLogTag stage=detection_received barcodes=${capture.barcodes.length}',
    );
    /// 当前画面中首个可用二维码文本。
    String? scannedText;
    for (final Barcode barcode in capture.barcodes) {
      /// 插件解码后的原始字符串。
      final String? rawValue = barcode.rawValue;
      if (rawValue != null && rawValue.trim().isNotEmpty) {
        scannedText = rawValue.trim();
        break;
      }
    }
    if (scannedText == null) {
      widget.logger.warning(
        message: '$bookSourceQrScanLogTag stage=detection_rejected reason=no_text',
      );
      return;
    }
    /// 二维码文本的 UTF-8 字节数，只记录大小而不记录正文。
    final int scannedBytes = utf8.encode(scannedText).length;
    widget.logger.info(
      message:
          '$bookSourceQrScanLogTag stage=detection_text_ready chars=${scannedText.length} bytes=$scannedBytes',
    );
    if (scannedBytes > maxQrTextBytes) {
      widget.logger.warning(
        message:
            '$bookSourceQrScanLogTag stage=detection_rejected reason=too_large bytes=$scannedBytes',
      );
      _resultHandled = true;
      await _stopScanner('oversized_result');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('二维码文本超过 64 KiB，已拒绝导入')),
        );
        _resultHandled = false;
        await _restartScanner();
      }
      return;
    }
    _resultHandled = true;
    await _stopScanner('valid_result');
    if (mounted) {
      widget.logger.info(message: '$bookSourceQrScanLogTag stage=scanner_result_returned');
      Navigator.of(context).pop<String>(scannedText);
    }
  }

  /// 【扫码诊断日志】捕获异步识别处理中的停止相机或路由返回异常。
  Future<void> _handleDetectionSafely(BarcodeCapture capture) async {
    try {
      await _handleDetection(capture);
    } catch (error, stackTrace) {
      widget.logger.error(
        message: '$bookSourceQrScanLogTag stage=detection_failed',
        error: error,
        stackTrace: stackTrace,
      );
      _resultHandled = false;
      if (mounted) {
        await _restartScanner();
      }
    }
  }

  /// 【扫码诊断日志】按原因停止相机，并完整记录停止结果或异常。
  Future<bool> _stopScanner(String reason) async {
    widget.logger.debug(
      message: '$bookSourceQrScanLogTag stage=scanner_stop_requested reason=$reason',
    );
    try {
      await _controller.stop();
      widget.logger.debug(
        message: '$bookSourceQrScanLogTag stage=scanner_stop_finished reason=$reason',
      );
      return true;
    } on MobileScannerException catch (error) {
      widget.logger.error(
        message:
            '$bookSourceQrScanLogTag stage=scanner_stop_failed reason=$reason code=${error.errorCode.name}',
        error: error,
      );
      return false;
    } catch (error, stackTrace) {
      widget.logger.error(
        message:
            '$bookSourceQrScanLogTag stage=scanner_stop_failed reason=$reason code=unexpected',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// 在相机暂时失败或异常二维码被拒绝后安全重启扫码。
  Future<void> _restartScanner() async {
    widget.logger.info(message: '$bookSourceQrScanLogTag stage=scanner_retry_requested');
    try {
      await _stopScanner('manual_retry');
      await _controller.start();
      /// 重试完成后的相机状态。
      final MobileScannerState retriedState = _controller.value;
      widget.logger.info(
        message:
            '$bookSourceQrScanLogTag stage=scanner_retry_finished running=${retriedState.isRunning} error=${retriedState.error?.errorCode.name ?? 'none'}',
      );
    } on MobileScannerException catch (error) {
      widget.logger.error(
        message:
            '$bookSourceQrScanLogTag stage=scanner_retry_threw code=${error.errorCode.name}',
        error: error,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('相机无法启动，请检查相机权限后重试')),
        );
      }
    } catch (error, stackTrace) {
      widget.logger.error(
        message: '$bookSourceQrScanLogTag stage=scanner_retry_failed_unexpectedly',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 在权限弹窗、切到后台和恢复前台时对齐原生相机生命周期。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.logger.debug(
      message:
          '$bookSourceQrScanLogTag stage=app_lifecycle state=${state.name} permission=${_controller.value.hasCameraPermission}',
    );
    if (!_controller.value.hasCameraPermission) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_startScanner());
      case AppLifecycleState.inactive:
        unawaited(_stopScanner('app_inactive'));
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        return;
    }
  }

  /// 释放相机、图像分析器和原生纹理资源。
  @override
  void dispose() {
    /// 【扫码诊断日志】供异步释放完成后使用的稳定日志引用。
    final AppLogger logger = widget.logger;
    // 【扫码诊断日志】扫码页面生命周期终点。
    widget.logger.info(
      message:
          '$bookSourceQrScanLogTag stage=scanner_route_disposed handled=$_resultHandled running=${_controller.value.isRunning}',
    );
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_handleControllerStateChanged);
    super.dispose();
    unawaited(_disposeController(logger));
  }

  /// 【扫码诊断日志】异步释放 controller 并记录原生相机资源释放结果。
  Future<void> _disposeController(AppLogger logger) async {
    try {
      await _controller.dispose();
      logger.debug(message: '$bookSourceQrScanLogTag stage=controller_disposed');
    } on MobileScannerException catch (error) {
      logger.error(
        message:
            '$bookSourceQrScanLogTag stage=controller_dispose_failed code=${error.errorCode.name}',
        error: error,
      );
    } catch (error, stackTrace) {
      logger.error(
        message: '$bookSourceQrScanLogTag stage=controller_dispose_failed code=unexpected',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 构建相机预览、取景框、关闭按钮和权限错误状态。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('扫一扫添加书源'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          MobileScanner(
            controller: _controller,
            useAppLifecycleState: false,
            onDetect: (BarcodeCapture capture) {
              unawaited(_handleDetectionSafely(capture));
            },
            errorBuilder: (BuildContext context, MobileScannerException error) {
              return _ScannerErrorView(onRetry: _restartScanner);
            },
          ),
          const IgnorePointer(child: _ScannerOverlay()),
        ],
      ),
    );
  }
}

/// 显示二维码取景区域和不会遮挡相机画面的操作说明。
final class _ScannerOverlay extends StatelessWidget {
  /// 创建静态扫码覆盖层。
  const _ScannerOverlay();

  /// 构建居中取景框和底部说明。
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: <Widget>[
          const Spacer(),
          Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          const SizedBox(height: 28),
          const DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0x99000000),
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                '将书源二维码放入框内，识别后可确认导入内容',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// 展示相机权限或设备能力错误，并允许用户主动重试。
final class _ScannerErrorView extends StatelessWidget {
  /// 创建扫码错误状态。
  const _ScannerErrorView({required this.onRetry});

  /// 用户主动重试相机启动的回调。
  final Future<void> Function() onRetry;

  /// 构建不泄漏插件内部错误的稳定提示。
  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.no_photography_outlined, color: Colors.white, size: 56),
              const SizedBox(height: 16),
              const Text(
                '无法使用相机，请允许相机权限或确认设备具有可用摄像头。',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  unawaited(onRetry());
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
