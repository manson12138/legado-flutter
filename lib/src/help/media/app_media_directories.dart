import 'dart:io';

import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

/// 本地媒体缓存分类；对应 media 根目录下的子目录。
///
/// 全部是“可以从网络重新获取”的可再生内容，因此统一落在系统缓存目录，区别于不可
/// 再生、必须持久保留的日志（见 `FileAppLogger`，落在应用支持目录）。
enum MediaCategory {
  /// 书籍/漫画封面图。
  cover('covers'),

  /// 用户头像；账号系统尚未实现，先占位目录，供后续功能直接复用下载器。
  avatar('avatars'),

  /// 漫画正文图片；漫画阅读器尚未实现，先占位目录。
  comic('comics'),

  /// 视频；视频播放器尚未实现，先占位目录。
  video('videos');

  const MediaCategory(this.directoryName);

  /// 分类对应的子目录名。
  final String directoryName;
}

/// 统一解析并预建本地媒体缓存目录。
///
/// 所有分类内容都可以从网络重新获取，因此根目录使用系统级缓存目录
/// （[getApplicationCacheDirectory]），存储紧张时允许系统自行回收；下载中间态使用
/// [getTemporaryDirectory]，比缓存目录更临时，即使被系统提前清理也不影响已经生效
/// 的正式文件。[warmUp] 由应用启动阶段调用一次，让 [cachedPathFor] 之后可以在
/// 高频渲染场景（例如书架封面）同步返回已知路径，不必等待异步 IO。
final class AppMediaDirectories {
  AppMediaDirectories._();

  /// 全局唯一实例。
  static final AppMediaDirectories instance = AppMediaDirectories._();

  /// 已解析的分类目录绝对路径；[warmUp] 完成后保证覆盖全部枚举值。
  final Map<MediaCategory, String> _resolvedPaths = <MediaCategory, String>{};

  /// 已解析的下载中间态目录绝对路径。
  String? _stagingPath;

  /// 同一进程内唯一的目录预建任务，避免首帧预热和页面按需访问重复执行文件 I/O。
  Future<void>? _warmUpTask;

  /// 预建全部分类目录和中间态目录；应用启动阶段调用一次即可。
  Future<void> warmUp() {
    final Future<void>? existingTask = _warmUpTask;
    if (existingTask != null) {
      return existingTask;
    }
    final Future<void> task = _performWarmUp();
    _warmUpTask = task;
    return task;
  }

  /// 执行唯一一次目录解析和创建；失败后允许下一次真实使用重新尝试。
  Future<void> _performWarmUp() async {
    try {
    /// 系统缓存根目录，存储紧张时允许被系统回收。
    final Directory cacheRoot = await getApplicationCacheDirectory();
    /// 本地媒体缓存统一挂在 media 子目录下，避免和系统或其他插件缓存混放。
    final String mediaRoot = path_util.join(cacheRoot.path, 'media');
    for (final MediaCategory category in MediaCategory.values) {
      final String directoryPath = path_util.join(mediaRoot, category.directoryName);
      await Directory(directoryPath).create(recursive: true);
      _resolvedPaths[category] = directoryPath;
    }
    /// 系统临时目录，比缓存目录更容易被提前回收，只用来存放下载中的临时文件。
    final Directory tempRoot = await getTemporaryDirectory();
    final String stagingPath = path_util.join(tempRoot.path, 'media_staging');
    await Directory(stagingPath).create(recursive: true);
    _stagingPath = stagingPath;
    } on Object {
      _warmUpTask = null;
      rethrow;
    }
  }

  /// 同步返回已预建的分类目录路径；[warmUp] 完成前恒为 null。
  String? cachedPathFor(MediaCategory category) => _resolvedPaths[category];

  /// 异步返回分类目录路径；[warmUp] 尚未完成时兜底自行补跑一次。
  Future<String> directoryPathFor(MediaCategory category) async {
    /// 已预建的路径。
    final String? cached = _resolvedPaths[category];
    if (cached != null) {
      return cached;
    }
    await warmUp();
    return _resolvedPaths[category]!;
  }

  /// 异步返回下载中间态目录路径；[warmUp] 尚未完成时兜底自行补跑一次。
  Future<String> stagingDirectoryPath() async {
    /// 已预建的路径。
    final String? cached = _stagingPath;
    if (cached != null) {
      return cached;
    }
    await warmUp();
    return _stagingPath!;
  }
}
