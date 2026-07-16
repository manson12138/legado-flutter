import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app/app_dependencies.dart';
import 'src/app/app_error_boundary.dart';
import 'src/app/legado_app.dart';
import 'src/help/logging/file_app_logger.dart';
import 'src/help/logging/app_logger.dart';
import 'src/help/logging/console_app_logger.dart';

/// 初始化 Flutter 运行环境并启动应用组合根。
///
/// 本方法只负责全局初始化、错误兜底和依赖装配，不承载任何书源、书架或阅读业务。
void main() {
  /// 文件日志器完成初始化前使用的后备日志实现。
  AppLogger activeLogger = const ConsoleAppLogger();

  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

      /// 默认日志器写入应用私有沙盒，并同时向设置页提供日志管理能力。
      final FileAppLogger fileLogger = await FileAppLogger.create();
      activeLogger = fileLogger;
      configureGlobalErrorHandling(fileLogger);

      /// 应用级依赖容器，仅在组合根创建并向下传递。
      final AppDependencies dependencies = AppDependencies.create(
        logger: fileLogger,
        logManager: fileLogger,
      );
      fileLogger.info(message: '应用日志系统初始化完成');
      runApp(LegadoApp(dependencies: dependencies));
    },
    (Object error, StackTrace stackTrace) {
      activeLogger.fatal(
        message: '应用启动或未捕获异步任务失败',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}
