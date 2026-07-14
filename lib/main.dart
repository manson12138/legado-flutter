import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app/app_dependencies.dart';
import 'src/app/app_error_boundary.dart';
import 'src/app/legado_app.dart';
import 'src/help/logging/app_logger.dart';
import 'src/help/logging/console_app_logger.dart';

/// 初始化 Flutter 运行环境并启动应用组合根。
///
/// 本方法只负责全局初始化、错误兜底和依赖装配，不承载任何书源、书架或阅读业务。
void main() {
  /// 启动阶段使用的日志实现，用于记录未被页面捕获的框架和异步错误。
  const AppLogger logger = ConsoleAppLogger();

  runZonedGuarded<void>(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      configureGlobalErrorHandling(logger);

      /// 应用级依赖容器，仅在组合根创建并向下传递。
      final AppDependencies dependencies = AppDependencies.create(logger: logger);
      runApp(LegadoApp(dependencies: dependencies));
    },
    (Object error, StackTrace stackTrace) {
      logger.error(
        message: '应用启动或未捕获异步任务失败',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}
