import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import '../../model/manga/manga_content_parser.dart';
import '../../model/manga/read_manga_coordinator.dart';
import '../../platform/reader_platform_service.dart';
import '../book_source/book_source_login_route.dart';
import 'manga_reader_contract.dart';
import 'manga_reader_screen.dart';
import 'manga_reader_view_model.dart';

/// 连接漫画 ViewModel、应用生命周期、系统阅读模式和页面的稳定路由层。
final class MangaReaderRoute extends StatefulWidget {
  /// 创建漫画阅读路由。
  const MangaReaderRoute({
    required this.dependencies,
    required this.bookUrl,
    required this.initialBook,
    required this.initialChapterIndex,
    required this.initialMessage,
    required this.initialIsInBookshelf,
    required this.initialChapters,
    required this.entry,
    super.key,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 漫画书籍稳定 URL。
  final String bookUrl;

  /// 入口已经持有的图片书籍快照。
  final Book? initialBook;

  /// 详情目录指定的初始章节；为空时使用书籍已有进度。
  final int? initialChapterIndex;

  /// 路由首帧展示的一次性换源结果提示。
  final String? initialMessage;

  /// 入口已知的书架成员事实。
  final bool? initialIsInBookshelf;

  /// 详情入口已经加载的完整目录快照。
  final List<BookChapter> initialChapters;

  /// 匿名阅读入口枚举：`detail`、`bookshelf` 或 `history`。
  final String entry;

  @override
  State<MangaReaderRoute> createState() => _MangaReaderRouteState();
}

/// 持有漫画 ViewModel、Effect、应用生命周期和系统阅读模式。
final class _MangaReaderRouteState extends State<MangaReaderRoute>
    with WidgetsBindingObserver {
  /// 页面生命周期独占的漫画协调器。
  late final ReadMangaCoordinator _coordinator;

  /// 页面生命周期独占的漫画 ViewModel。
  late final MangaReaderViewModel _viewModel;

  /// 一次性 Effect 订阅。
  late final StreamSubscription<MangaReaderEffect> _effectSubscription;

  /// 打开路由时所属的游客或登录账号作用域。
  late final int? _routeUserId;

  /// 是否已经因账号切换安排关闭，避免重复导航。
  bool _closingForUserScopeChange = false;

  /// 是否已经打开书源登录页，避免 Effect 连续触发重复路由。
  bool _openingSourceLogin = false;

  /// 是否已经打开整书换源页，避免并发迁移同一本书。
  bool _openingChangeSource = false;

  /// 漫画路由进入前的 Flutter 全局图片缓存字节上限。
  late final int _previousImageCacheMaximumBytes;

  /// 本漫画路由实际应用的图片缓存字节上限。
  late final int _mangaImageCacheMaximumBytes;

  /// 漫画解码缓存按估算字节限制为 64 MiB，而不是按图片数量无限保留。
  static const int _maximumDecodedImageCacheBytes = 64 * 1024 * 1024;

  /// 系统栏、方向和屏幕常亮平台边界。
  final ReaderPlatformService _platformService =
      const MethodChannelReaderPlatformService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _configureDecodedImageBudget();
    _routeUserId = widget.dependencies.currentUserScope.userId.value;
    widget.dependencies.currentUserScope.userId.addListener(
      _handleUserScopeChanged,
    );
    _coordinator = ReadMangaCoordinator(
      sourceGateway: widget.dependencies.bookSourceGateway,
      cacheGateway: widget.dependencies.readerCacheGateway,
      standardService: widget.dependencies.standardBookSourceService,
      imageGateway: widget.dependencies.mangaImageGateway,
      contentParser: const MangaContentParser(),
      cancellationTokenFactory: widget.dependencies.createHttpCancellationToken,
    );
    _viewModel = MangaReaderViewModel(
      bookUrl: widget.bookUrl,
      initialBook: widget.initialBook,
      initialChapterIndex: widget.initialChapterIndex,
      initialIsInBookshelf: widget.initialIsInBookshelf,
      initialChapters: widget.initialChapters,
      entry: widget.entry,
      bookshelfGateway: widget.dependencies.bookshelfGateway,
      readingHistoryGateway: widget.dependencies.readingHistoryGateway,
      loadBookChapters: widget.dependencies.loadBookChapters,
      saveReadingProgress: widget.dependencies.saveReadingProgress,
      recordReadingHistory: widget.dependencies.recordReadingHistory,
      addBookToBookshelf: widget.dependencies.addBookToBookshelf,
      coordinator: _coordinator,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
    unawaited(_enterReaderMode());
    _viewModel.onIntent(const InitializeMangaReaderIntent());
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      /// 去除路由消息首尾空白后的可见提示。
      final String message = widget.initialMessage?.trim() ?? '';
      if (mounted && message.isNotEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      }
    });
  }

  /// 进入漫画阅读系统模式；平台桥缺失时页面仍可继续使用 Flutter 阅读能力。
  Future<void> _enterReaderMode() async {
    try {
      await _platformService.enterReader(
        keepScreenOn: true,
        useSystemBrightness: true,
        readerBrightness: 1,
        orientationMode: ReaderOrientationMode.system,
        fullScreen: true,
      );
    } on Object {
      // 系统栏或常亮能力降级不覆盖漫画正文的真实加载结果。
    }
  }

  /// 临时收紧 Flutter `ImageCache.maximumSizeBytes`，超大单图仍显示但不会长期进入缓存。
  void _configureDecodedImageBudget() {
    /// 应用进入漫画前已有的全局字节预算。
    final int existingLimit = PaintingBinding.instance.imageCache.maximumSizeBytes;
    _previousImageCacheMaximumBytes = existingLimit;
    _mangaImageCacheMaximumBytes = existingLimit < _maximumDecodedImageCacheBytes
        ? existingLimit
        : _maximumDecodedImageCacheBytes;
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        _mangaImageCacheMaximumBytes;
  }

  /// 仅当上限仍是本路由设置值时恢复旧预算，避免覆盖其他生命周期调整。
  void _restoreDecodedImageBudget() {
    if (PaintingBinding.instance.imageCache.maximumSizeBytes ==
        _mangaImageCacheMaximumBytes) {
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          _previousImageCacheMaximumBytes;
    }
  }

  /// 离开漫画阅读模式并恢复 App 级系统栏和方向策略。
  Future<void> _exitReaderMode() async {
    try {
      await _platformService.exitReader();
    } on Object {
      // 路由已经退出，平台恢复失败不能阻止 Widget 资源释放。
    }
  }

  /// 显示 ViewModel 发出的短提示。
  void _handleEffect(MangaReaderEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case ShowMangaReaderMessageEffect(:final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case OpenMangaSourceLoginEffect(
          sourceUrl: final String sourceUrl,
          title: final String title,
        ):
        unawaited(_openSourceLogin(sourceUrl: sourceUrl, title: title));
      case OpenMangaChangeSourceEffect(bookUrl: final String bookUrl):
        unawaited(_openChangeSource(bookUrl));
    }
  }

  /// 暂时退出阅读模式并打开受控书源登录页；仅用户点击完成后强制刷新章节。
  Future<void> _openSourceLogin({
    required String sourceUrl,
    required String title,
  }) async {
    if (_openingSourceLogin || _openingChangeSource) {
      return;
    }
    _openingSourceLogin = true;
    try {
      await _viewModel.saveProgress();
      await _exitReaderMode();
      if (!mounted) {
        return;
      }
      /// 非空结果代表用户点击了完成；返回手势和取消均不触发章节请求。
      final BookSourceLoginResult? result =
          await Navigator.of(context).push<BookSourceLoginResult>(
        MaterialPageRoute<BookSourceLoginResult>(
          builder: (BuildContext context) => BookSourceLoginRoute(
            dependencies: widget.dependencies,
            sourceUrl: sourceUrl,
            title: title,
            capturePageResult: true,
          ),
        ),
      );
      if (!mounted) {
        return;
      }
      await _enterReaderMode();
      if (result != null) {
        _viewModel.onIntent(
          const RetryMangaChapterIntent(forceRefresh: true),
        );
      }
    } on Object {
      if (mounted) {
        await _enterReaderMode();
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(content: Text('打开书源登录失败，请稍后重试')),
            );
        }
      }
    } finally {
      _openingSourceLogin = false;
    }
  }

  /// 暂时退出阅读模式；图片兼容换源成功后用新主键替换当前漫画路由。
  Future<void> _openChangeSource(String oldBookUrl) async {
    if (_openingChangeSource || _openingSourceLogin) {
      return;
    }
    _openingChangeSource = true;
    try {
      await _viewModel.saveProgress();
      await _exitReaderMode();
      if (!mounted) {
        return;
      }
      /// 整书换源页面返回的事务结果。
      final ChangeBookSourceResult? result =
          await Navigator.of(context).pushNamed<ChangeBookSourceResult>(
        AppRoute.changeBookSource,
        arguments: ChangeBookSourceRouteArguments(bookUrl: oldBookUrl),
      );
      if (!mounted) {
        return;
      }
      if (result == null) {
        await _enterReaderMode();
        return;
      }
      if (!result.book.isImage) {
        await _enterReaderMode();
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(content: Text('换源结果不是图片类型，已拒绝进入漫画阅读器')),
            );
        }
        return;
      }
      /// 新路由首帧展示的成功或非阻断警告。
      final String resultMessage = result.warnings.isEmpty
          ? '已切换到“${result.book.originName}”'
          : '换源已完成；${result.warnings.join('；')}';
      _viewModel.prepareForRouteReplacement();
      unawaited(
        Navigator.of(context).pushReplacementNamed<void, void>(
          AppRoute.mangaReader,
          arguments: MangaReaderRouteArguments(
            bookUrl: result.book.bookUrl,
            initialMessage: resultMessage,
            initialBook: result.book,
            initialIsInBookshelf: true,
            entry: widget.entry,
          ),
        ),
      );
    } on Object {
      if (mounted) {
        await _enterReaderMode();
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(content: Text('打开整书换源失败，请稍后重试')),
            );
        }
      }
    } finally {
      _openingChangeSource = false;
    }
  }

  /// 应用退后台或失去活动状态时立即保存当前图片进度。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_enterReaderMode());
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _viewModel.onIntent(const SaveMangaProgressIntent());
    }
  }

  /// 系统内存压力时先保存稳定位置，再释放所有可从磁盘重建的 Flutter 图片解码缓存。
  @override
  void didHaveMemoryPressure() {
    _viewModel.onIntent(const MangaMemoryPressureIntent());
    _clearDecodedImageCache();
  }

  /// 账号切换时阻止旧作用域继续写入，清理解码图片并关闭旧漫画路由。
  void _handleUserScopeChanged() {
    if (_closingForUserScopeChange ||
        widget.dependencies.currentUserScope.userId.value == _routeUserId) {
      return;
    }
    _closingForUserScopeChange = true;
    _viewModel.invalidateForUserScopeChange();
    _clearDecodedImageCache();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) {
        unawaited(Navigator.of(context).maybePop());
      }
    });
  }

  /// 清除可重建的普通和仍被追踪的 Flutter 图片解码对象，不删除磁盘漫画缓存。
  void _clearDecodedImageCache() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MangaReaderUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (
        BuildContext context,
        AsyncSnapshot<MangaReaderUiState> snapshot,
      ) {
        /// Stream 首帧始终回退 ViewModel 同步状态。
        final MangaReaderUiState state = snapshot.data ?? _viewModel.state;
        return MangaReaderScreen(
          state: state,
          resolveImage: _viewModel.resolveImage,
          createImageCancellationToken:
              _viewModel.createImageCancellationToken,
          onIntent: _viewModel.onIntent,
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.dependencies.currentUserScope.userId.removeListener(
      _handleUserScopeChanged,
    );
    unawaited(_effectSubscription.cancel());
    _viewModel.dispose();
    _restoreDecodedImageBudget();
    unawaited(_exitReaderMode());
    super.dispose();
  }
}
