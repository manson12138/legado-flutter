import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app/app_error_boundary.dart';
import 'src/app/legado_app.dart';
import 'src/help/logging/file_app_logger.dart';
import 'src/help/logging/app_logger.dart';
import 'src/help/logging/console_app_logger.dart';
import 'src/help/logging/deferred_app_log_service.dart';
import 'src/help/media/app_media_directories.dart';
import 'src/help/crash_reporting/crash_report_manager.dart';
import 'src/api/remote_app/remote_app_service_config.dart';

/// 初始化 Flutter 运行环境并启动应用组合根。
///
/// 本方法只负责全局初始化、错误兜底和依赖装配，不承载任何书源、书架或阅读业务。
void main() {
  /// 文件日志器完成初始化前使用的后备日志实现。
  AppLogger activeLogger = const ConsoleAppLogger();
  /// 崩溃目录就绪后接管 Zone 未捕获异常；启动极早期失败仍使用后备日志。
  CrashReportManager? activeCrashReportManager;

  runZonedGuarded<Future<void>>(
    () async {
      activeLogger.info(tag: appStartupLogTag, message: 'stage=main_started');
      WidgetsFlutterBinding.ensureInitialized();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // App 固定竖屏，不支持横屏；阅读器可以按单书配置临时切换，退出阅读器后会自行恢复本设置。
      /// 固定方向请求无需阻塞 Flutter 首帧；阅读器仍会在进入和退出时自行覆盖及恢复方向。
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]).catchError((Object error) {
          activeLogger.warning(
            tag: appStartupLogTag,
            message: 'stage=preferred_orientation_degraded',
            error: error,
          );
        }),
      );

      /// 默认日志器写入应用私有沙盒，并同时向设置页提供日志管理能力。
      final DeferredAppLogService deferredLogService = DeferredAppLogService();
      activeLogger = deferredLogService;
      /// 远端服务、准入缓存与崩溃报告共享实际安装包版本，避免升级后继续恢复旧状态。
      final RemoteAppServiceConfig remoteAppConfig =
          await _resolveRemoteAppConfig(deferredLogService);
      final CrashReportManager crashReportManager = CrashReportManager.deferred(productId: remoteAppConfig.productId, versionName: remoteAppConfig.appVersionName, versionCode: remoteAppConfig.appVersionCode, channel: remoteAppConfig.channel);
      activeCrashReportManager = crashReportManager;
      configureGlobalErrorHandling(deferredLogService, crashReportManager);

      deferredLogService.info(tag: appStartupLogTag, message: 'stage=run_app');
      /// 完整业务依赖在 Flutter 第一帧后由启动壳创建，避免原生启动页等待同步对象装配。
      runApp(
        LegadoBootstrapApp(
          logger: deferredLogService,
          logManager: deferredLogService,
          crashReportManager: crashReportManager,
          remoteAppConfig: remoteAppConfig,
        ),
      );
      /// 媒体目录仅在封面、下载等功能真正使用时才是必需条件，首帧后预热即可。
      unawaited(_initializeDeferredFileServices(deferredLogService, crashReportManager));
      unawaited(_warmUpMediaDirectories(deferredLogService));
    },
    (Object error, StackTrace stackTrace) {
      activeCrashReportManager?.record(source: 'zone', error: error, stackTrace: stackTrace);
      // 启动前失败无法保证报告目录可用，后备日志器仍保留原有职责。
      activeLogger.fatal(
        tag: appStartupLogTag,
        message: '应用启动或未捕获异步任务失败',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}

/// 读取当前安装包版本；平台元数据异常时保留网络能力，但禁用旧准入缓存恢复。
Future<RemoteAppServiceConfig> _resolveRemoteAppConfig(
  AppLogger logger,
) async {
  try {
    final RemoteAppServiceConfig config =
        await RemoteAppServiceConfig.fromInstalledPackage();
    if (!config.hasInstalledVersionIdentity) {
      logger.warning(
        tag: appStartupLogTag,
        message: 'stage=installed_app_version_degraded reason=empty_version_name',
      );
    }
    return config;
  } on Object catch (error) {
    logger.warning(
      tag: appStartupLogTag,
      message:
          'stage=installed_app_version_degraded reason=platform_metadata_unavailable error_type=${error.runtimeType}',
      error: error,
    );
    return RemoteAppServiceConfig.fromEnvironment();
  }
}

/// 在首帧后初始化文件日志和崩溃目录；任一步失败都保持控制台日志降级而不影响界面。
Future<void> _initializeDeferredFileServices(
  DeferredAppLogService logService,
  CrashReportManager crashReportManager,
) async {
  try {
    final FileAppLogger fileLogger = await FileAppLogger.create();
    logService.activate(fileLogger);
    fileLogger.info(tag: appStartupLogTag, message: 'stage=file_logger_ready');
  } on Object catch (error) {
    logService.warning(
      tag: appStartupLogTag,
      message: 'stage=file_logger_degraded',
      error: error,
    );
  }
  try {
    await crashReportManager.initialize();
    logService.info(tag: appStartupLogTag, message: 'stage=crash_reporting_ready');
  } on Object catch (error) {
    logService.warning(
      tag: appStartupLogTag,
      message: 'stage=crash_reporting_degraded',
      error: error,
    );
  }
}

/// 在首帧后尽力预建可再生媒体目录；失败时由具体调用方的按需初始化继续兜底。
Future<void> _warmUpMediaDirectories(AppLogger logger) async {
  try {
    await AppMediaDirectories.instance.warmUp();
    logger.info(tag: appStartupLogTag, message: 'stage=media_directories_ready');
  } on Object catch (error) {
    logger.warning(
      tag: appStartupLogTag,
      message: 'stage=media_directories_warm_up_degraded',
      error: error,
    );
  }
}
