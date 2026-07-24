import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app/app_dependencies.dart';
import 'src/app/app_error_boundary.dart';
import 'src/app/legado_app.dart';
import 'src/help/logging/file_app_logger.dart';
import 'src/help/logging/app_logger.dart';
import 'src/help/logging/console_app_logger.dart';
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
      WidgetsFlutterBinding.ensureInitialized();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // App 固定竖屏，不支持横屏；阅读器可以按单书配置临时切换，退出阅读器后会自行恢复本设置。
      await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);

      /// 默认日志器写入应用私有沙盒，并同时向设置页提供日志管理能力。
      final FileAppLogger fileLogger = await FileAppLogger.create();
      activeLogger = fileLogger;
      /// 远端服务与崩溃报告共享同一组构建版本配置，避免上报版本漂移。
      final RemoteAppServiceConfig remoteAppConfig = RemoteAppServiceConfig.fromEnvironment();
      final CrashReportManager crashReportManager = await CrashReportManager.create(productId: remoteAppConfig.productId, versionName: remoteAppConfig.appVersionName, versionCode: remoteAppConfig.appVersionCode, channel: remoteAppConfig.channel);
      activeCrashReportManager = crashReportManager;
      configureGlobalErrorHandling(fileLogger, crashReportManager);

      /// 预建封面等本地媒体缓存目录，使封面渲染时可以同步判断本地是否已有缓存。
      await AppMediaDirectories.instance.warmUp();

      /// 应用级依赖容器，仅在组合根创建并向下传递。
      final AppDependencies dependencies = AppDependencies.create(
        logger: fileLogger,
        logManager: fileLogger,
        crashReportManager: crashReportManager,
        remoteAppConfig: remoteAppConfig,
      );
      fileLogger.info(message: '应用日志系统初始化完成');
      runApp(LegadoApp(dependencies: dependencies));
    },
    (Object error, StackTrace stackTrace) {
      activeCrashReportManager?.record(source: 'zone', error: error, stackTrace: stackTrace);
      // 启动前失败无法保证报告目录可用，后备日志器仍保留原有职责。
      activeLogger.fatal(
        message: '应用启动或未捕获异步任务失败',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}
