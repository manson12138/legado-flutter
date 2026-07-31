import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import '../../help/logging/app_logger.dart';
import '../../platform/reader_platform_service.dart';
import '../book_info/book_info_contract.dart';
import '../change_chapter_source/change_chapter_source_contract.dart';
import '../change_chapter_source/change_chapter_source_screen.dart';
import '../change_chapter_source/change_chapter_source_view_model.dart';
import '../theme/app_tokens.dart';
import 'reader_action_sheets.dart';
import 'reader_contract.dart';
import 'reader_download_sheet.dart';
import 'reader_settings_sheet.dart';
import 'reader_screen.dart';
import 'reader_view_model.dart';

/// 连接阅读 ViewModel、生命周期、滚动恢复、业务面板、导航和平台 Effect 的路由层。
final class ReaderRoute extends StatefulWidget {
  /// 创建阅读路由。
  const ReaderRoute({
    required this.dependencies,
    required this.bookUrl,
    this.initialChapterIndex,
    this.initialMessage,
    this.initialBook,
    this.initialIsInBookshelf,
    this.initialChapters = const <BookChapter>[],
    this.entry = 'bookshelf',
    super.key,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// M07 书架传入的稳定书籍 URL。
  final String bookUrl;

  /// 从详情目录进入时指定的初始章节索引；为空则使用阅读进度。
  final int? initialChapterIndex;

  /// 新路由首帧需要展示的一次性提示，例如整书换源结果。
  final String? initialMessage;

  /// 书架、历史或详情入口传入的书籍快照。
  final Book? initialBook;

  /// 路由入口已知的书架成员事实；为空时由 ViewModel 并行补查。
  final bool? initialIsInBookshelf;

  /// 详情页直接阅读时传入的未入架目录快照。
  final List<BookChapter> initialChapters;

  /// 阅读入口的受控埋点枚举。
  final String entry;

  /// 创建路由状态。
  @override
  State<ReaderRoute> createState() => _ReaderRouteState();
}

/// 持有 ViewModel、滚动控制器、系统生命周期和面板生命周期。
final class _ReaderRouteState extends State<ReaderRoute> with WidgetsBindingObserver {
  /// 页面生命周期内唯一 ReaderViewModel。
  late final ReaderViewModel _viewModel;

  /// Effect 订阅。
  late final StreamSubscription<ReaderEffect> _effectSubscription;

  /// 瞬时滚动控制器，不写入业务状态。
  final ScrollController _scrollController = ScrollController();

  /// 阅读器键盘监听焦点，用于接收桌面键盘和 Android 音量键事件。
  final FocusNode _keyboardFocusNode = FocusNode(debugLabel: 'ReaderVolumeKeyFocus');

  /// 系统栏和屏幕常亮平台服务。
  final ReaderPlatformService _platformService = const MethodChannelReaderPlatformService();

  /// 当前已经展示的业务面板。
  ReaderSheet? _shownSheet;

  /// 当前已经交给 Navigator 展示的同书名书架冲突。
  ReaderBookshelfConflictDialog? _shownBookshelfConflict;

  /// 最近已经执行的字符锚点恢复请求编号。
  int _lastRestoreRequestId = -1;

  /// 阅读器系统信息刷新定时器，用于轮询电量等低频信息。
  Timer? _systemInfoTimer;

  /// 程序化退出前允许 Navigator 真正弹出当前路由。
  bool _allowPop = false;

  /// 是否已经打开换源页面，阻止重复 Effect 创建多条路由。
  bool _openingChangeSource = false;

  /// 是否已经打开书籍详情页，阻止重复 Effect 创建多条路由。
  bool _openingBookInfo = false;

  /// 创建 ViewModel、订阅 Effect 并开始初始化。
  @override
  void initState() {
    super.initState();
    /// 【搜书诊断日志】阅读页面实例创建，后续初始化日志由同一 bookId 串联。
    widget.dependencies.logger.info(
      tag: bookReaderEntryLogTag,
      message: '文本阅读页面创建 bookId=${appLogDiagnosticId(widget.bookUrl)}',
    );
    WidgetsBinding.instance.addObserver(this);
    /// MMKV 中没有当前用户与书籍的完成标记时，首帧直接建立先导页状态。
    final bool initialShowIntroPage =
        !widget.dependencies.readerIntroPreferences.hasSeen(widget.bookUrl);
    /// 当前安装尚未实际展示过工具栏时，仅允许本阅读路由领取一次自动展示资格。
    final bool initialMenuVisible =
        widget.dependencies.readerMenuPreferences.claimInitialVisibility();
    _viewModel = ReaderViewModel(
      bookUrl: widget.bookUrl,
      initialChapterIndex: widget.initialChapterIndex,
      initialBook: widget.initialBook,
      initialIsInBookshelf: widget.initialIsInBookshelf,
      initialChapters: widget.initialChapters,
      initialDisplayConfig:
          widget.dependencies.readerCacheGateway.currentDisplayConfig,
      initialShowIntroPage: initialShowIntroPage,
      initialMenuVisible: initialMenuVisible,
      markIntroSeen: () {
        widget.dependencies.readerIntroPreferences.markSeen(widget.bookUrl);
      },
      markInitialMenuShown: () {
        widget.dependencies.readerMenuPreferences.markShown();
      },
      entry: widget.entry,
      bookshelfGateway: widget.dependencies.bookshelfGateway,
      readingHistoryGateway: widget.dependencies.readingHistoryGateway,
      loadBookChapters: widget.dependencies.loadBookChapters,
      restoreReadingProgress: widget.dependencies.restoreReadingProgress,
      saveReadingProgress: widget.dependencies.saveReadingProgress,
      bookmarkGateway: widget.dependencies.bookmarkGateway,
      bookContentProcessGateway:
          widget.dependencies.bookContentProcessGateway,
      replaceRuleGateway: widget.dependencies.replaceRuleGateway,
      cacheGateway: widget.dependencies.readerCacheGateway,
      coordinator: widget.dependencies.createReadBookCoordinator(),
      saveBookContentProcess: widget.dependencies.saveBookContentProcess,
      recordReadingHistory: widget.dependencies.recordReadingHistory,
      addBookToBookshelf: widget.dependencies.addBookToBookshelf,
      changeBookSource: widget.dependencies.changeBookSource,
      analyticsRecorder:
          widget.dependencies.remoteBookSourceSyncService.recordAnalyticsEvent,
      logger: widget.dependencies.logger,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
    _viewModel.onIntent(const InitializeReaderIntent());
    /// 路由替换后的提示必须等 Scaffold 完成首帧构建再展示。
    final String? initialMessage = widget.initialMessage;
    if (initialMessage != null && initialMessage.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(initialMessage)),
          );
        }
      });
    }
  }

  /// 前后台切换时立即保存稳定阅读进度。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !_openingChangeSource &&
        !_openingBookInfo &&
        _viewModel.state.loadState == ReaderLoadState.ready) {
      /// 回到前台后重新应用 iOS 系统栏与常亮设置，阅读位置仍由现有 Dart 状态保持。
      unawaited(
        _platformService.enterReader(
          keepScreenOn: _viewModel.state.config.keepScreenOn,
          useSystemBrightness: _viewModel.state.config.useSystemBrightness,
          readerBrightness: _viewModel.state.config.readerBrightness,
          orientationMode: _viewModel.state.config.orientationMode,
          fullScreen: _viewModel.state.config.fullScreen,
        ),
      );
      unawaited(_refreshSystemInfo());
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _viewModel.onIntent(const PauseReaderIntent());
    }
  }

  /// 旋转、分屏或系统尺寸变化后按稳定字符锚点重新计算临时滚动位置。
  @override
  void didChangeMetrics() {
    _lastRestoreRequestId = -1;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (mounted) {
        _restoreScrollPosition(_viewModel.state);
      }
    });
  }

  /// 系统内存警告时保留当前正文与稳定锚点，只释放可重建的相邻章缓存。
  @override
  void didHaveMemoryPressure() {
    _viewModel.onIntent(const ReaderMemoryPressureIntent());
  }

  /// 执行系统栏、常亮、消息和关闭路由副作用。
  void _handleEffect(ReaderEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case EnterReaderSystemEffect(config: final ReaderDisplayConfig config):
        /// 【搜书诊断日志】收到该 Effect 表示书籍、目录和阅读配置初始化成功。
        widget.dependencies.logger.info(
          tag: bookReaderEntryLogTag,
          message: '阅读器初始化通过，进入阅读系统模式 '
              'bookId=${appLogDiagnosticId(widget.bookUrl)} keepScreenOn=${config.keepScreenOn}',
        );
        unawaited(
          _platformService.enterReader(
            keepScreenOn: config.keepScreenOn,
            useSystemBrightness: config.useSystemBrightness,
            readerBrightness: config.readerBrightness,
            orientationMode: config.orientationMode,
            fullScreen: config.fullScreen,
          ),
        );
        _startSystemInfoTimer();
      case UpdateReaderSystemEffect(config: final ReaderDisplayConfig config):
        unawaited(_platformService.setFullScreen(config.fullScreen));
        unawaited(_platformService.setKeepScreenOn(config.keepScreenOn));
        unawaited(
          _platformService.setBrightness(
            useSystemBrightness: config.useSystemBrightness,
            value: config.readerBrightness,
          ),
        );
        unawaited(_platformService.setOrientation(config.orientationMode));
      case ExitReaderSystemEffect():
        // FLUTTER_REWRITE_DEBUG_LOG：关闭链路第一步恢复阅读器进入前的系统状态。
        widget.dependencies.logger.info(
          tag: readerEdgeSwipeExitLogTag,
          message: '$readerEdgeSwipeExitDebugLogMarker exitSystemEffect',
        );
        unawaited(_platformService.exitReader());
        _stopSystemInfoTimer();
      case CloseReaderRouteEffect():
        // FLUTTER_REWRITE_DEBUG_LOG：关闭链路第二步允许 Navigator 真正退出当前阅读路由。
        widget.dependencies.logger.info(
          tag: readerEdgeSwipeExitLogTag,
          message: '$readerEdgeSwipeExitDebugLogMarker closeRouteEffect '
              'allowPop=$_allowPop',
        );
        widget.dependencies.logger.info(
          tag: bookReaderEntryLogTag,
          message: '阅读页面准备退出 bookId=${appLogDiagnosticId(widget.bookUrl)}',
        );
        if (_allowPop) {
          return;
        }
        setState(() {
          _allowPop = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
          if (mounted) {
            Navigator.of(context).pop();
          }
        });
      case ShowReaderMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case CopyReaderTextEffect(text: final String text, message: final String message):
        unawaited(Clipboard.setData(ClipboardData(text: text)));
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case ShareReaderContentImageEffect(imageUrl: final String imageUrl):
        unawaited(_shareContentImage(imageUrl));
      case OpenReaderBookSourceChangeEffect(bookUrl: final String bookUrl):
        unawaited(_openChangeSource(bookUrl));
      case OpenReaderBookInfoEffect(book: final Book book):
        unawaited(_openBookInfo(book));
    }
  }

  /// 打开 Android/iOS 系统分享面板，让用户保存、打开或转发正文图片。
  Future<void> _shareContentImage(String imageUrl) async {
    try {
      /// iPad 分享面板需要的当前路由全局锚点。
      final RenderObject? renderObject = context.findRenderObject();
      /// 系统分享弹窗在大屏设备上的显示区域。
      final Rect? shareOrigin = renderObject is RenderBox
          ? renderObject.localToGlobal(Offset.zero) & renderObject.size
          : null;
      await SharePlus.instance.share(
        ShareParams(
          uri: Uri.parse(imageUrl),
          title: '正文图片',
          subject: '正文图片',
          sharePositionOrigin: shareOrigin,
        ),
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('正文图片分享失败')));
      }
    }
  }

  /// 暂时退出阅读系统模式并打开当前书籍详情；详情返回阅读参数时替换旧阅读路由。
  Future<void> _openBookInfo(Book book) async {
    if (_openingBookInfo) {
      return;
    }
    _openingBookInfo = true;
    _stopSystemInfoTimer();
    await _platformService.exitReader();
    if (!mounted) {
      _openingBookInfo = false;
      return;
    }
    /// 详情页复用搜索候选模型，保留当前来源的完整书籍元数据。
    final SearchBook searchBook = _toSearchBook(book);
    /// 详情页主动阅读时返回的新阅读路由参数；普通返回时为空。
    final ReaderRouteArguments? result =
        await Navigator.of(context).pushNamed<ReaderRouteArguments>(
      AppRoute.bookInfo,
      arguments: BookInfoRouteArguments(
        group: BookSearchResultGroup(
          key: '${book.name.length}:${book.name}${book.author}',
          books: <SearchBook>[searchBook],
        ),
        selectedBook: searchBook,
        returnReaderResult: true,
      ),
    );
    if (!mounted) {
      return;
    }
    _openingBookInfo = false;
    if (result == null) {
      await _platformService.enterReader(
        keepScreenOn: _viewModel.state.config.keepScreenOn,
        useSystemBrightness: _viewModel.state.config.useSystemBrightness,
        readerBrightness: _viewModel.state.config.readerBrightness,
        orientationMode: _viewModel.state.config.orientationMode,
        fullScreen: _viewModel.state.config.fullScreen,
      );
      if (!mounted) {
        return;
      }
      _startSystemInfoTimer();
      _keyboardFocusNode.requestFocus();
      return;
    }
    /// 用户在详情页选择阅读后替换当前旧阅读器，避免叠出重复阅读路由。
    unawaited(
      Navigator.of(context).pushReplacementNamed<void, void>(
        AppRoute.reader,
        arguments: result,
      ),
    );
  }

  /// 把当前书籍事实转换为详情页需要的单来源候选。
  SearchBook _toSearchBook(Book book) {
    return SearchBook(
      bookUrl: book.bookUrl,
      origin: book.origin,
      originName: book.originName,
      name: book.name,
      author: book.author,
      type: book.type,
      kind: book.kind,
      coverUrl: book.coverUrl,
      intro: book.intro,
      wordCount: book.wordCount,
      latestChapterTitle: book.latestChapterTitle,
      tocUrl: book.tocUrl,
      time: book.lastCheckTime,
      variable: book.variable,
      originOrder: book.originOrder,
    );
  }

  /// 暂时退出阅读系统模式，换源成功后用新主键替换当前阅读路由。
  Future<void> _openChangeSource(String oldBookUrl) async {
    if (_openingChangeSource) {
      return;
    }
    _openingChangeSource = true;
    _stopSystemInfoTimer();
    try {
      await _platformService.exitReader();
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
        await _restoreReaderAfterExternalRoute();
        return;
      }
      /// 换源成功后用于新阅读路由的稳定主键。
      final String newBookUrl = result.book.bookUrl;
      /// 新阅读路由首帧展示的成功或非阻断警告。
      final String resultMessage = result.warnings.isEmpty
          ? '已切换到“${result.book.originName}”'
          : '换源已完成；${result.warnings.join('；')}';
      /// 数据事务已经完成，当前旧路由必须被替换，不能继续持有已删除旧主键。
      unawaited(
        Navigator.of(context).pushReplacementNamed<void, void>(
          AppRoute.reader,
          arguments: ReaderRouteArguments(
            bookUrl: newBookUrl,
            initialMessage: resultMessage,
            initialBook: result.book,
          ),
        ),
      );
    } on Object {
      await _restoreReaderAfterExternalRoute();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('打开整书换源失败，请稍后重试')),
          );
      }
    } finally {
      _openingChangeSource = false;
    }
  }

  /// 从外部页面返回后恢复阅读窗口配置、低频系统信息刷新和键盘/音量键焦点。
  Future<void> _restoreReaderAfterExternalRoute() async {
    if (!mounted) {
      return;
    }
    try {
      await _platformService.enterReader(
        keepScreenOn: _viewModel.state.config.keepScreenOn,
        useSystemBrightness: _viewModel.state.config.useSystemBrightness,
        readerBrightness: _viewModel.state.config.readerBrightness,
        orientationMode: _viewModel.state.config.orientationMode,
        fullScreen: _viewModel.state.config.fullScreen,
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('阅读显示状态恢复失败')),
          );
      }
    }
    if (!mounted) {
      return;
    }
    _startSystemInfoTimer();
    _keyboardFocusNode.requestFocus();
  }

  /// 启动低频系统信息刷新，避免每帧读取电量。
  void _startSystemInfoTimer() {
    _systemInfoTimer?.cancel();
    unawaited(_refreshSystemInfo());
    _systemInfoTimer = Timer.periodic(const Duration(minutes: 1), (Timer timer) {
      unawaited(_refreshSystemInfo());
    });
  }

  /// 停止系统信息刷新。
  void _stopSystemInfoTimer() {
    _systemInfoTimer?.cancel();
    _systemInfoTimer = null;
  }

  /// 从平台读取电量等系统信息并发送给 ViewModel。
  Future<void> _refreshSystemInfo() async {
    if (!mounted) {
      return;
    }
    /// 平台返回的电量百分比；为空表示宿主不可用或系统拒绝。
    final int? batteryLevel = await _platformService.getBatteryLevel();
    if (!mounted) {
      return;
    }
    _viewModel.onIntent(UpdateReaderSystemInfoIntent(batteryLevel: batteryLevel));
  }

  /// 处理音量键翻页；打开面板或用户关闭开关时不拦截系统按键。
  void _handleReaderKey(KeyEvent event, ReaderUiState state) {
    if (event is! KeyDownEvent ||
        state.loadState != ReaderLoadState.ready ||
        state.activeSheet != null ||
        state.config.readingMode != ReaderReadingMode.continuous ||
        !state.config.volumeKeyTurnPage) {
      return;
    }
    /// 当前物理或逻辑按键。
    final LogicalKeyboardKey logicalKey = event.logicalKey;
    if (logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      _openPreviousContinuousPageOrChapter(state);
      return;
    }
    if (logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      _openNextContinuousPageOrChapter(state);
    }
  }

  /// 连续阅读模式下优先向上滚动一个视口，到达顶部后进入上一章。
  void _openPreviousContinuousPageOrChapter(ReaderUiState state) {
    if (_scrollController.hasClients) {
      /// 当前连续阅读滚动位置。
      final ScrollPosition position = _scrollController.position;
      /// 向上翻一屏后的目标像素。
      final double target = (position.pixels - position.viewportDimension)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (target < position.pixels) {
        _scrollController.animateTo(
          target,
          duration: DurationToken.medium,
          curve: AnimationToken.standard,
        );
        return;
      }
    }
    if (state.canGoPrevious) {
      _viewModel.onIntent(const OpenPreviousChapterIntent());
    }
  }

  /// 连续阅读模式下优先向下滚动一个视口，到达底部后进入下一章。
  void _openNextContinuousPageOrChapter(ReaderUiState state) {
    if (_scrollController.hasClients) {
      /// 当前连续阅读滚动位置。
      final ScrollPosition position = _scrollController.position;
      /// 向下翻一屏后的目标像素。
      final double target = (position.pixels + position.viewportDimension)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (target > position.pixels) {
        _scrollController.animateTo(
          target,
          duration: DurationToken.medium,
          curve: AnimationToken.standard,
        );
        return;
      }
    }
    if (state.canGoNext) {
      _viewModel.onIntent(const OpenNextChapterIntent());
    }
  }

  /// 根据稳定字符锚点换算本次布局的临时滚动偏移，字体变化后可重复执行。
  void _restoreScrollPosition(ReaderUiState state) {
    if (state.restoreRequestId == _lastRestoreRequestId ||
        state.loadState != ReaderLoadState.ready) {
      return;
    }
    _lastRestoreRequestId = state.restoreRequestId;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      /// 当前完整正文长度。
      final int textLength = state.content?.text.length ?? 0;
      /// 当前稳定字符位置。
      final int characterOffset = state.anchor?.characterOffset ?? 0;
      /// 字符进度比例；像素只作为本次布局的瞬时投影，不持久化。
      final double progress = textLength <= 1
          ? 0
          : (characterOffset / (textLength - 1)).clamp(0, 1).toDouble();
      /// 当前字体、宽度和安全区下的临时像素目标。
      final double target = _scrollController.position.maxScrollExtent * progress;
      _scrollController.jumpTo(
        target.clamp(0, _scrollController.position.maxScrollExtent).toDouble(),
      );
    });
  }

  /// 根据 UiState 同步展示一次阅读器同书名书架冲突对话框。
  void _syncBookshelfConflict(ReaderBookshelfConflictDialog? conflict) {
    if (conflict == null ||
        identical(conflict, _shownBookshelfConflict)) {
      return;
    }
    _shownBookshelfConflict = conflict;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) async {
      if (!mounted ||
          !identical(conflict, _shownBookshelfConflict)) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) {
          return _ReaderBookshelfConflictAlert(
            conflict: conflict,
            onOverwrite: () {
              Navigator.of(context).pop();
              _viewModel.onIntent(
                const OverwriteReaderBookshelfConflictIntent(),
              );
            },
            onAddAsNew: () {
              Navigator.of(context).pop();
              _viewModel.onIntent(
                const AddReaderBookshelfConflictAsNewIntent(),
              );
            },
          );
        },
      );
      if (identical(conflict, _shownBookshelfConflict)) {
        _shownBookshelfConflict = null;
        if (_viewModel.state.bookshelfConflict != null) {
          _viewModel.onIntent(
            const DismissReaderBookshelfConflictIntent(),
          );
        }
      }
    });
  }

  /// 根据 UiState 同步一次目录、设置或书签面板。
  void _syncSheet(ReaderSheet? sheet) {
    if (sheet == null || identical(sheet, _shownSheet)) {
      return;
    }
    _shownSheet = sheet;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) async {
      if (!mounted || !identical(sheet, _shownSheet)) {
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (BuildContext context) {
          return StreamBuilder<ReaderUiState>(
            stream: _viewModel.states,
            initialData: _viewModel.state,
            builder: (BuildContext context, AsyncSnapshot<ReaderUiState> snapshot) {
              /// 面板当前实时状态。
              final ReaderUiState state = snapshot.data ?? _viewModel.state;
              return Theme(
                data: _readerSheetTheme(Theme.of(context), state.config),
                child: _buildSheet(sheet, state),
              );
            },
          );
        },
      );
      if (identical(sheet, _shownSheet)) {
        _shownSheet = null;
        if (identical(_viewModel.state.activeSheet, sheet)) {
          _viewModel.onIntent(const DismissReaderSheetIntent());
        } else {
          _syncSheet(_viewModel.state.activeSheet);
        }
      }
    });
  }

  /// 让目录、书签、设置及其他阅读器面板统一跟随当前阅读配色。
  ThemeData _readerSheetTheme(ThemeData theme, ReaderDisplayConfig config) {
    final Color background = Color(config.backgroundColorValue);
    final Color foreground = Color(config.textColorValue);
    return theme.copyWith(
      canvasColor: background,
      scaffoldBackgroundColor: background,
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: background),
      iconTheme: IconThemeData(color: foreground),
      textTheme: theme.textTheme.apply(
        bodyColor: foreground,
        displayColor: foreground,
      ),
    );
  }

  /// 构建目录、显示设置或书签面板内容。
  Widget _buildSheet(ReaderSheet sheet, ReaderUiState state) {
    /// 当前阅读书籍的可空快照，局部分支检查后由 Dart 类型提升，避免强制空值断言。
    final Book? currentBook = state.book;
    return switch (sheet) {
      ReaderTocSheet() => _ReaderTocSheetBody(state: state, onIntent: _viewModel.onIntent),
      ReaderSettingsSheet() => ReaderSettingsSheetBody(
        initialConfig: state.config,
        onApply: (ReaderDisplayConfig config) {
          Navigator.of(context).pop();
          _viewModel.onIntent(UpdateReaderConfigIntent(config));
        },
      ),
      ReaderBookmarksSheet() => _ReaderBookmarksSheetBody(
        bookmarks: state.bookmarks,
        onIntent: _viewModel.onIntent,
      ),
      ReaderSearchSheet() => ReaderSearchSheetBody(
        state: state,
        onIntent: _viewModel.onIntent,
      ),
      ReaderBookmarkEditSheet(bookmark: final Bookmark bookmark) => ReaderBookmarkEditSheetBody(
        bookmark: bookmark,
        onIntent: _viewModel.onIntent,
      ),
      ReaderReplaceInfoSheet() => ReaderReplaceInfoSheetBody(state: state),
      ReaderContentProcessesSheet() => ReaderContentProcessesSheetBody(
        state: state,
        onIntent: _viewModel.onIntent,
      ),
      ReaderFutureFeaturesSheet() => const ReaderFutureFeaturesSheetBody(),
      ReaderChangeChapterSourceSheet(
        chapterIndex: final int chapterIndex,
        chapterTitle: final String chapterTitle,
      ) =>
        currentBook == null
            ? const SizedBox.shrink()
            : _ChangeChapterSourceSheetHost(
                dependencies: widget.dependencies,
                book: currentBook,
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                totalChapterCount: state.chapters.length,
                onReplace: (
                  int index,
                  String content,
                  int candidateCount,
                  int startedAtMilliseconds,
                ) {
                  Navigator.of(context).pop();
                  _viewModel.onIntent(
                    SaveReaderChapterSourceContentIntent(
                      index,
                      content,
                      candidateCount: candidateCount,
                      startedAtMilliseconds: startedAtMilliseconds,
                    ),
                  );
                },
                onDismiss: () => Navigator.of(context).pop(),
              ),
      ReaderDownloadSheet() => currentBook == null
          ? const SizedBox.shrink()
          : ReaderDownloadSheetBody(
              coordinator: widget.dependencies.downloadCoordinator,
              book: currentBook,
              chapters: state.chapters,
              currentChapterIndex: state.currentChapterIndex,
            ),
    };
  }

  /// 释放生命周期、Effect、滚动和正文协调资源，并兜底恢复平台窗口。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopSystemInfoTimer();
    _effectSubscription.cancel();
    _scrollController.dispose();
    _keyboardFocusNode.dispose();
    _viewModel.dispose();
    unawaited(_platformService.exitReader());
    super.dispose();
  }

  /// 订阅状态、同步面板与字符锚点，并拦截系统返回以先保存进度。
  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        // FLUTTER_REWRITE_DEBUG_LOG：区分系统边缘返回与 Flutter 阅读器边缘识别器发起的关闭。
        widget.dependencies.logger.info(
          tag: readerEdgeSwipeExitLogTag,
          message: '$readerEdgeSwipeExitDebugLogMarker systemPop '
              'didPop=$didPop allowPop=$_allowPop',
        );
        if (!didPop) {
          _viewModel.onIntent(const CloseReaderIntent());
        }
      },
      child: StreamBuilder<ReaderUiState>(
        stream: _viewModel.states,
        initialData: _viewModel.state,
        builder: (BuildContext context, AsyncSnapshot<ReaderUiState> snapshot) {
          /// 当前可渲染状态。
          final ReaderUiState state = snapshot.data ?? _viewModel.state;
          _restoreScrollPosition(state);
          _syncSheet(state.activeSheet);
          _syncBookshelfConflict(state.bookshelfConflict);
          return KeyboardListener(
            focusNode: _keyboardFocusNode,
            autofocus: true,
            onKeyEvent: (KeyEvent event) {
              _handleReaderKey(event, state);
            },
            child: ReaderScreen(
              state: state,
              onIntent: _viewModel.onIntent,
              scrollController: _scrollController,
              logger: widget.dependencies.logger,
            ),
          );
        },
      ),
    );
  }
}

/// 阅读器显式加入书架时展示作者、来源和目录差异的同书名确认框。
final class _ReaderBookshelfConflictAlert extends StatelessWidget {
  /// 创建只有覆盖和再次添加两个业务选项的确认框。
  const _ReaderBookshelfConflictAlert({
    required this.conflict,
    required this.onOverwrite,
    required this.onAddAsNew,
  });

  /// 当前待确认的同书名冲突快照。
  final ReaderBookshelfConflictDialog conflict;

  /// 把新来源覆盖合并到现有书架记录的回调。
  final VoidCallback onOverwrite;

  /// 明确保留为第二条同名书架记录的回调。
  final VoidCallback onAddAsNew;

  /// 构建作者、来源、章节数和覆盖含义说明。
  @override
  Widget build(BuildContext context) {
    /// 现有书籍作者的安全显示文本。
    final String existingAuthor = conflict.existingBook.author.isEmpty
        ? '未知作者'
        : conflict.existingBook.author;
    /// 待加入书籍作者的安全显示文本。
    final String incomingAuthor = conflict.incomingBook.author.isEmpty
        ? '未知作者'
        : conflict.incomingBook.author;
    /// 现有书源的安全显示文本。
    final String existingSource = conflict.existingBook.originName.isEmpty
        ? '未知来源'
        : conflict.existingBook.originName;
    /// 待加入书源的安全显示文本。
    final String incomingSource = conflict.incomingBook.originName.isEmpty
        ? '未知来源'
        : conflict.incomingBook.originName;
    return AlertDialog(
      icon: const Icon(Icons.library_add_check_outlined),
      title: const Text('书架中已有同名书籍'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '《${conflict.incomingBook.name}》',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Text(
              '书架现有：$existingAuthor · $existingSource'
              '（${conflict.existingBook.totalChapterNum} 章）',
            ),
            const SizedBox(height: 8),
            Text(
              '本次添加：$incomingAuthor · $incomingSource'
              '（${conflict.incomingChapters.length} 章）',
            ),
            const SizedBox(height: 16),
            const Text(
              '选择覆盖后会把两者视为同一本书，新书源和目录成为当前来源；'
              '阅读进度、分组、排序、备注、封面和单书阅读设置会合并保留。',
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: onAddAsNew, child: const Text('再次添加')),
        FilledButton(onPressed: onOverwrite, child: const Text('覆盖')),
      ],
    );
  }
}

/// 展示完整目录并高亮当前章节。
final class _ReaderTocSheetBody extends StatefulWidget {
  /// 创建目录面板。
  const _ReaderTocSheetBody({required this.state, required this.onIntent});

  /// 当前阅读状态。
  final ReaderUiState state;

  /// 阅读 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 创建目录筛选和滚动定位状态。
  @override
  State<_ReaderTocSheetBody> createState() => _ReaderTocSheetBodyState();
}

/// 持有目录显示选项和滚动控制器。
final class _ReaderTocSheetBodyState extends State<_ReaderTocSheetBody> {
  /// 每一行目录的近似高度，用于初始定位当前章节。
  static const double _rowExtent = 56;

  /// 是否显示卷标题。
  bool _showVolumes = true;

  /// 是否按倒序显示目录；每次打开目录时默认正序。
  bool _descending = false;

  /// 目录滚动控制器。
  late final ScrollController _scrollController;

  /// 初始化目录滚动位置。
  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: _initialOffset(widget.state),
    );
  }

  /// 释放目录滚动控制器。
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 构建可跳转目录列表。
  @override
  Widget build(BuildContext context) {
    /// 当前筛选后的目录行。
    final List<int> visibleIndexes = _visibleChapterIndexes(widget.state);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        children: <Widget>[
          ListTile(
            title: const Text('目录'),
            subtitle: Text('当前第 ${widget.state.currentChapterIndex + 1} 章'),
            trailing: Tooltip(
              message: _descending ? '切换为正序' : '切换为倒序',
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    _descending = !_descending;
                  });
                  _scheduleCurrentChapterPosition();
                },
                icon: Icon(_descending ? Icons.arrow_upward : Icons.arrow_downward),
                label: Text(_descending ? '倒序' : '正序'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SpacingToken.medium,
              0,
              SpacingToken.medium,
              SpacingToken.small,
            ),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilterChip(
                selected: _showVolumes,
                label: const Text('卷标题'),
                onSelected: (bool selected) {
                  setState(() {
                    _showVolumes = selected;
                  });
                  _scheduleCurrentChapterPosition();
                },
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemExtent: _rowExtent,
              itemCount: visibleIndexes.length,
              itemBuilder: (BuildContext context, int index) {
                /// 原始章节索引。
                final int chapterIndex = visibleIndexes[index];
                /// 当前目录章节。
                final BookChapter chapter = widget.state.chapters[chapterIndex];
                return ListTile(
                  selected: chapterIndex == widget.state.currentChapterIndex,
                  enabled: !chapter.isVolume,
                  leading: chapter.isVolume
                      ? const Icon(Icons.folder_outlined)
                      : Text('${chapterIndex + 1}'),
                  title: Text(chapter.title),
                  onTap: chapter.isVolume
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          widget.onIntent(OpenReaderChapterIntent(chapterIndex));
                        },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 计算当前章节在筛选列表中的初始滚动偏移。
  double _initialOffset(ReaderUiState state) {
    /// 当前筛选后的目录行。
    final List<int> indexes = _visibleChapterIndexes(state);
    /// 当前章节在筛选列表中的位置。
    final int visibleIndex = indexes.indexOf(state.currentChapterIndex);
    if (visibleIndex <= 0) {
      return 0;
    }
    return (visibleIndex * _rowExtent - _rowExtent * 2).clamp(0, double.infinity).toDouble();
  }

  /// 在目录选项变化后的下一帧把当前章节重新定位到可见区域。
  void _scheduleCurrentChapterPosition() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      /// 当前选项下的可见目录索引。
      final List<int> indexes = _visibleChapterIndexes(widget.state);
      /// 当前章节在可见目录中的位置。
      final int visibleIndex = indexes.indexOf(widget.state.currentChapterIndex);
      if (visibleIndex < 0) {
        return;
      }
      /// 预留两行上方上下文，并限制在当前列表的有效滚动范围内。
      final double targetOffset = (visibleIndex * _rowExtent - _rowExtent * 2)
          .clamp(0, _scrollController.position.maxScrollExtent)
          .toDouble();
      _scrollController.jumpTo(targetOffset);
    });
  }

  /// 根据卷标题开关生成可见目录索引。
  List<int> _visibleChapterIndexes(ReaderUiState state) {
    /// 可见目录索引。
    final List<int> indexes = <int>[];
    for (int offset = 0; offset < state.chapters.length; offset += 1) {
      /// 根据当前顺序把可见位置映射到原始章节索引。
      final int index = _descending ? state.chapters.length - 1 - offset : offset;
      /// 当前章节。
      final BookChapter chapter = state.chapters[index];
      if (_showVolumes || !chapter.isVolume || index == state.currentChapterIndex) {
        indexes.add(index);
      }
    }
    return indexes;
  }
}

/// 展示书签摘要并提供跳转和删除操作。
final class _ReaderBookmarksSheetBody extends StatelessWidget {
  /// 创建书签面板。
  const _ReaderBookmarksSheetBody({required this.bookmarks, required this.onIntent});

  /// 当前书籍全部书签。
  final List<Bookmark> bookmarks;

  /// 阅读 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 构建书签空状态或列表。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: Column(
        children: <Widget>[
          ListTile(
            title: const Text('书签'),
            trailing: TextButton.icon(
              onPressed: bookmarks.isEmpty
                  ? null
                  : () => onIntent(const ExportReaderBookmarksIntent()),
              icon: const Icon(Icons.content_copy),
              label: const Text('导出'),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: bookmarks.isEmpty
                ? const Center(child: Text('还没有书签'))
                : ListView.builder(
                    itemCount: bookmarks.length,
                    itemBuilder: (BuildContext context, int index) {
                      /// 当前书签。
                      final Bookmark bookmark = bookmarks[index];
                      return ListTile(
                        title: Text(bookmark.chapterName),
                        subtitle: Text(
                          bookmark.content,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          onIntent(OpenReaderBookmarkIntent(bookmark));
                        },
                        trailing: Wrap(
                          spacing: SpacingToken.xSmall,
                          children: <Widget>[
                            IconButton(
                              onPressed: () {
                                Navigator.of(context).pop();
                                onIntent(
                                  ShowReaderSheetIntent(ReaderBookmarkEditSheet(bookmark)),
                                );
                              },
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: '编辑书签',
                            ),
                            IconButton(
                              onPressed: () => _confirmDelete(context, bookmark),
                              icon: const Icon(Icons.delete_outline),
                              tooltip: '删除书签',
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 二次确认后删除书签，避免误触丢失备注。
  Future<void> _confirmDelete(BuildContext context, Bookmark bookmark) async {
    /// 用户确认结果。
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('删除书签'),
              content: const Text('确定删除这条书签吗？'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('删除'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (confirmed) {
      onIntent(DeleteReaderBookmarkIntent(bookmark));
    }
  }
}

/// 承载单章换源面板独立 ViewModel 生命周期，正文拉取成功后回调外层阅读器保存。
final class _ChangeChapterSourceSheetHost extends StatefulWidget {
  /// 创建单章换源面板宿主。
  const _ChangeChapterSourceSheetHost({
    required this.dependencies,
    required this.book,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.totalChapterCount,
    required this.onReplace,
    required this.onDismiss,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 正在被单章换源的书籍事实；书籍主键本身不会改变。
  final Book book;

  /// 待替换正文的目标章节索引。
  final int chapterIndex;

  /// 待替换正文的目标章节标题。
  final String chapterTitle;

  /// 打开面板时目标书籍的完整目录长度。
  final int totalChapterCount;

  /// 候选正文拉取完成后的回调，由外层阅读器负责保存和重新加载。
  final void Function(
    int chapterIndex,
    String content,
    int candidateCount,
    int startedAtMilliseconds,
  ) onReplace;

  /// 用户主动关闭面板且不替换任何正文时的回调。
  final VoidCallback onDismiss;

  /// 创建面板宿主状态。
  @override
  State<_ChangeChapterSourceSheetHost> createState() => _ChangeChapterSourceSheetHostState();
}

/// 持有单章换源面板独立 ViewModel 和 Effect 订阅。
final class _ChangeChapterSourceSheetHostState extends State<_ChangeChapterSourceSheetHost> {
  /// 面板生命周期内唯一 ViewModel。
  late final ChangeChapterSourceViewModel _viewModel;

  /// Effect 订阅。
  late final StreamSubscription<ChangeChapterSourceEffect> _effectSubscription;

  /// 创建 ViewModel 并订阅 Effect。
  @override
  void initState() {
    super.initState();
    _viewModel = ChangeChapterSourceViewModel(
      book: widget.book,
      chapterIndex: widget.chapterIndex,
      chapterTitle: widget.chapterTitle,
      totalChapterCount: widget.totalChapterCount,
      coordinator: widget.dependencies.createChangeChapterSourceCoordinator(),
      cancellationTokenFactory: widget.dependencies.createHttpCancellationToken,
      logger: widget.dependencies.logger,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 把候选正文回调给外层阅读器保存，或按用户操作关闭面板。
  void _handleEffect(ChangeChapterSourceEffect effect) {
    switch (effect) {
      case ShowChangeChapterSourceMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case ReplaceChangeChapterSourceContentEffect(
        chapterIndex: final int chapterIndex,
        content: final String content,
        candidateCount: final int candidateCount,
        startedAtMilliseconds: final int startedAtMilliseconds,
      ):
        widget.onReplace(
          chapterIndex,
          content,
          candidateCount,
          startedAtMilliseconds,
        );
      case DismissChangeChapterSourceEffect():
        widget.onDismiss();
    }
  }

  /// 释放 Effect 订阅和 ViewModel。
  @override
  void dispose() {
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 订阅状态并渲染单章换源纯 UI。
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ChangeChapterSourceUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (BuildContext context, AsyncSnapshot<ChangeChapterSourceUiState> snapshot) {
        return ChangeChapterSourceSheetBody(
          state: snapshot.data ?? _viewModel.state,
          onIntent: _viewModel.onIntent,
        );
      },
    );
  }
}
