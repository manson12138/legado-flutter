import 'package:flutter/material.dart';

import '../ui/components/app_state_views.dart';
import '../ui/home/welcome_route.dart';
import '../ui/book_source/book_source_route.dart';
import '../ui/book_info/book_info_contract.dart';
import '../ui/book_info/book_info_route.dart';
import '../ui/search/search_route.dart';
import '../ui/bookshelf/bookshelf_route.dart';
import '../ui/reader/book_reader_route.dart';
import '../ui/local_book_import/local_book_import_route.dart';
import '../ui/log_management/log_management_route.dart';
import '../ui/settings/settings_route.dart';
import '../help/logging/app_logger.dart';
import 'app_dependencies.dart';
import 'app_route.dart';

/// 统一负责把路由名称映射为页面，并在入口处注入页面依赖。
final class AppRouter {
  /// 创建绑定应用依赖容器的路由器。
  const AppRouter({required this.dependencies});

  /// 组合根提供的依赖容器，路由只负责向页面构造函数传递。
  final AppDependencies dependencies;

  /// 根据 Flutter 路由设置创建目标页面。
  Route<void> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoute.welcome:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return WelcomeRoute(dependencies: dependencies);
          },
        );
      case AppRoute.settings:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return const SettingsRoute();
          },
        );
      case AppRoute.logManagement:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return LogManagementRoute(dependencies: dependencies);
          },
        );
      case AppRoute.bookSourceManagement:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return BookSourceManagementRoute(dependencies: dependencies);
          },
        );
      case AppRoute.search:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return SearchRoute(dependencies: dependencies);
          },
        );
      case AppRoute.bookshelf:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return BookshelfRoute(dependencies: dependencies);
          },
        );
      case AppRoute.localBookImport:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return LocalBookImportRoute(dependencies: dependencies);
          },
        );
      case AppRoute.bookInfo:
        /// 详情页必须由搜索页携带候选来源参数。
        final Object? arguments = settings.arguments;
        if (arguments is BookInfoRouteArguments) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (BuildContext context) {
              return BookInfoRoute(dependencies: dependencies, arguments: arguments);
            },
          );
        }
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return const AppFatalErrorView(message: '书籍详情缺少有效路由参数');
          },
        );
      case AppRoute.reader:
        /// M07 兼容字符串 bookUrl，详情目录入口使用带初始章节的参数对象。
        final Object? readerArguments = settings.arguments;
        /// 归一化后的阅读器参数。
        final ReaderRouteArguments? normalizedReaderArguments = switch (readerArguments) {
          String bookUrl when bookUrl.isNotEmpty => ReaderRouteArguments(bookUrl: bookUrl),
          ReaderRouteArguments arguments when arguments.bookUrl.isNotEmpty => arguments,
          _ => null,
        };
        if (normalizedReaderArguments != null) {
          /// 【搜书诊断日志】阅读路由参数验证成功，只记录不可逆书籍标识。
          dependencies.logger.info(
            tag: bookReaderEntryLogTag,
            message: '阅读路由参数验证成功 '
                'bookId=${appLogDiagnosticId(normalizedReaderArguments.bookUrl)} '
                'initialChapterIndex=${normalizedReaderArguments.initialChapterIndex}',
          );
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (BuildContext context) {
              return BookReaderRoute(
                dependencies: dependencies,
                bookUrl: normalizedReaderArguments.bookUrl,
                initialChapterIndex: normalizedReaderArguments.initialChapterIndex,
              );
            },
          );
        }
        /// 【搜书诊断日志】阅读路由缺少参数时在创建错误页前记录原因。
        dependencies.logger.error(
          tag: bookReaderEntryLogTag,
          message: '阅读路由参数验证失败 argumentType=${readerArguments.runtimeType}',
        );
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return const AppFatalErrorView(message: '阅读入口缺少有效书籍 URL。');
          },
        );
      default:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return AppFatalErrorView(
              message: '未找到路由：${settings.name ?? '未知'}',
            );
          },
        );
    }
  }
}
