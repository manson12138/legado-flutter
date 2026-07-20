import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import '../../help/logging/app_logger.dart';
import '../../platform/reader_platform_service.dart';
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

  /// 最近已经执行的字符锚点恢复请求编号。
  int _lastRestoreRequestId = -1;

  /// 阅读器系统信息刷新定时器，用于轮询电量等低频信息。
  Timer? _systemInfoTimer;

  /// 程序化退出前允许 Navigator 真正弹出当前路由。
  bool _allowPop = false;

  /// 是否已经打开换源页面，阻止重复 Effect 创建多条路由。
  bool _openingChangeSource = false;

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
    _viewModel = ReaderViewModel(
      bookUrl: widget.bookUrl,
      initialChapterIndex: widget.initialChapterIndex,
      bookshelfGateway: widget.dependencies.bookshelfGateway,
      loadBookChapters: widget.dependencies.loadBookChapters,
      restoreReadingProgress: widget.dependencies.restoreReadingProgress,
      saveReadingProgress: widget.dependencies.saveReadingProgress,
      bookmarkGateway: widget.dependencies.bookmarkGateway,
      replaceRuleGateway: widget.dependencies.replaceRuleGateway,
      cacheGateway: widget.dependencies.readerCacheGateway,
      coordinator: widget.dependencies.createReadBookCoordinator(),
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
        _viewModel.state.loadState == ReaderLoadState.ready) {
      /// 回到前台后重新应用 iOS 系统栏与常亮设置，阅读位置仍由现有 Dart 状态保持。
      unawaited(
        _platformService.enterReader(
          keepScreenOn: _viewModel.state.config.keepScreenOn,
          useSystemBrightness: _viewModel.state.config.useSystemBrightness,
          readerBrightness: _viewModel.state.config.readerBrightness,
          orientationMode: _viewModel.state.config.orientationMode,
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
          ),
        );
        _startSystemInfoTimer();
      case UpdateReaderSystemEffect(config: final ReaderDisplayConfig config):
        unawaited(_platformService.setKeepScreenOn(config.keepScreenOn));
        unawaited(
          _platformService.setBrightness(
            useSystemBrightness: config.useSystemBrightness,
            value: config.readerBrightness,
          ),
        );
        unawaited(_platformService.setOrientation(config.orientationMode));
      case ExitReaderSystemEffect():
        unawaited(_platformService.exitReader());
        _stopSystemInfoTimer();
      case CloseReaderRouteEffect():
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
      case OpenReaderBookSourceChangeEffect(bookUrl: final String bookUrl):
        unawaited(_openChangeSource(bookUrl));
    }
  }

  /// 暂时退出阅读系统模式，换源成功后用新主键替换当前阅读路由。
  Future<void> _openChangeSource(String oldBookUrl) async {
    if (_openingChangeSource) {
      return;
    }
    _openingChangeSource = true;
    await _platformService.exitReader();
    if (!mounted) {
      _openingChangeSource = false;
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
    _openingChangeSource = false;
    if (result == null) {
      await _platformService.enterReader(
        keepScreenOn: _viewModel.state.config.keepScreenOn,
        useSystemBrightness: _viewModel.state.config.useSystemBrightness,
        readerBrightness: _viewModel.state.config.readerBrightness,
        orientationMode: _viewModel.state.config.orientationMode,
      );
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
        ),
      ),
    );
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
              return _buildSheet(sheet, state);
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

  /// 构建目录、显示设置或书签面板内容。
  Widget _buildSheet(ReaderSheet sheet, ReaderUiState state) {
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
      ReaderFutureFeaturesSheet() => const ReaderFutureFeaturesSheetBody(),
      ReaderChangeChapterSourceSheet(
        chapterIndex: final int chapterIndex,
        chapterTitle: final String chapterTitle,
      ) =>
        state.book == null
            ? const SizedBox.shrink()
            : _ChangeChapterSourceSheetHost(
                dependencies: widget.dependencies,
                book: state.book!,
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                totalChapterCount: state.chapters.length,
                onReplace: (int index, String content) {
                  Navigator.of(context).pop();
                  _viewModel.onIntent(SaveReaderChapterSourceContentIntent(index, content));
                },
                onDismiss: () => Navigator.of(context).pop(),
              ),
      ReaderDownloadSheet() => state.book == null
          ? const SizedBox.shrink()
          : ReaderDownloadSheetBody(
              coordinator: widget.dependencies.downloadCoordinator,
              book: state.book!,
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
            ),
          );
        },
      ),
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
            trailing: FilterChip(
              selected: _showVolumes,
              label: const Text('卷标题'),
              onSelected: (bool selected) {
                setState(() {
                  _showVolumes = selected;
                });
              },
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

  /// 根据卷标题开关生成可见目录索引。
  List<int> _visibleChapterIndexes(ReaderUiState state) {
    /// 可见目录索引。
    final List<int> indexes = <int>[];
    for (int index = 0; index < state.chapters.length; index += 1) {
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
  final void Function(int chapterIndex, String content) onReplace;

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
      ):
        widget.onReplace(chapterIndex, content);
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
