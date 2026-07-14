import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/reader_content.dart';
import '../../platform/reader_platform_service.dart';
import '../theme/app_tokens.dart';
import 'reader_contract.dart';
import 'reader_screen.dart';
import 'reader_view_model.dart';

/// 连接阅读 ViewModel、生命周期、滚动恢复、业务面板、导航和平台 Effect 的路由层。
final class ReaderRoute extends StatefulWidget {
  /// 创建阅读路由。
  const ReaderRoute({
    required this.dependencies,
    required this.bookUrl,
    super.key,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// M07 书架传入的稳定书籍 URL。
  final String bookUrl;

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

  /// 系统栏和屏幕常亮平台服务。
  final ReaderPlatformService _platformService = const MethodChannelReaderPlatformService();

  /// 当前已经展示的业务面板。
  ReaderSheet? _shownSheet;

  /// 最近已经执行的字符锚点恢复请求编号。
  int _lastRestoreRequestId = -1;

  /// 程序化退出前允许 Navigator 真正弹出当前路由。
  bool _allowPop = false;

  /// 创建 ViewModel、订阅 Effect 并开始初始化。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _viewModel = ReaderViewModel(
      bookUrl: widget.bookUrl,
      bookshelfGateway: widget.dependencies.bookshelfGateway,
      loadBookChapters: widget.dependencies.loadBookChapters,
      restoreReadingProgress: widget.dependencies.restoreReadingProgress,
      saveReadingProgress: widget.dependencies.saveReadingProgress,
      bookmarkGateway: widget.dependencies.bookmarkGateway,
      cacheGateway: widget.dependencies.readerCacheGateway,
      coordinator: widget.dependencies.createReadBookCoordinator(),
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
    _viewModel.onIntent(const InitializeReaderIntent());
  }

  /// 前后台切换时立即保存稳定阅读进度。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _viewModel.onIntent(const PauseReaderIntent());
    }
  }

  /// 执行系统栏、常亮、消息和关闭路由副作用。
  void _handleEffect(ReaderEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case EnterReaderSystemEffect(keepScreenOn: final bool keepScreenOn):
        unawaited(_platformService.enterReader(keepScreenOn: keepScreenOn));
      case UpdateReaderSystemEffect(keepScreenOn: final bool keepScreenOn):
        unawaited(_platformService.setKeepScreenOn(keepScreenOn));
      case ExitReaderSystemEffect():
        unawaited(_platformService.exitReader());
      case CloseReaderRouteEffect():
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
        _viewModel.onIntent(const DismissReaderSheetIntent());
      }
    });
  }

  /// 构建目录、显示设置或书签面板内容。
  Widget _buildSheet(ReaderSheet sheet, ReaderUiState state) {
    return switch (sheet) {
      ReaderTocSheet() => _ReaderTocSheetBody(state: state, onIntent: _viewModel.onIntent),
      ReaderSettingsSheet() => _ReaderSettingsSheetBody(
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
    };
  }

  /// 释放生命周期、Effect、滚动和正文协调资源，并兜底恢复平台窗口。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _effectSubscription.cancel();
    _scrollController.dispose();
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
          return ReaderScreen(
            state: state,
            onIntent: _viewModel.onIntent,
            scrollController: _scrollController,
          );
        },
      ),
    );
  }
}

/// 展示完整目录并高亮当前章节。
final class _ReaderTocSheetBody extends StatelessWidget {
  /// 创建目录面板。
  const _ReaderTocSheetBody({required this.state, required this.onIntent});

  /// 当前阅读状态。
  final ReaderUiState state;

  /// 阅读 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 构建可跳转目录列表。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        children: <Widget>[
          const ListTile(title: Text('目录')),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: state.chapters.length,
              itemBuilder: (BuildContext context, int index) {
                /// 当前目录章节。
                final BookChapter chapter = state.chapters[index];
                return ListTile(
                  selected: index == state.currentChapterIndex,
                  enabled: !chapter.isVolume,
                  leading: chapter.isVolume ? const Icon(Icons.folder_outlined) : Text('${index + 1}'),
                  title: Text(chapter.title),
                  onTap: chapter.isVolume
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          onIntent(OpenReaderChapterIntent(index));
                        },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 在本地草稿中调整显示配置，仅点击应用时持久化并触发重排。
final class _ReaderSettingsSheetBody extends StatefulWidget {
  /// 创建显示设置面板。
  const _ReaderSettingsSheetBody({required this.initialConfig, required this.onApply});

  /// 打开面板时的配置快照。
  final ReaderDisplayConfig initialConfig;

  /// 应用完整配置回调。
  final ValueChanged<ReaderDisplayConfig> onApply;

  /// 创建设置面板状态。
  @override
  State<_ReaderSettingsSheetBody> createState() => _ReaderSettingsSheetBodyState();
}

/// 持有尚未应用的滑杆和颜色草稿。
final class _ReaderSettingsSheetBodyState extends State<_ReaderSettingsSheetBody> {
  /// 当前草稿配置。
  late ReaderDisplayConfig _draft;

  /// 初始化草稿。
  @override
  void initState() {
    super.initState();
    _draft = widget.initialConfig;
  }

  /// 构建字号、行距、段距、边距、颜色、替换和常亮设置。
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(SpacingToken.medium),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('显示设置', style: Theme.of(context).textTheme.titleLarge),
          _slider(
            label: '字号 ${_draft.fontSize.toStringAsFixed(0)}',
            value: _draft.fontSize,
            min: 14,
            max: 32,
            divisions: 18,
            onChanged: (double value) => _update(_draft.copyWith(fontSize: value)),
          ),
          _slider(
            label: '行距 ${_draft.lineHeight.toStringAsFixed(1)}',
            value: _draft.lineHeight,
            min: 1.2,
            max: 2.4,
            divisions: 12,
            onChanged: (double value) => _update(_draft.copyWith(lineHeight: value)),
          ),
          _slider(
            label: '段距 ${_draft.paragraphSpacing.toStringAsFixed(0)}',
            value: _draft.paragraphSpacing,
            min: 0,
            max: 32,
            divisions: 16,
            onChanged: (double value) => _update(_draft.copyWith(paragraphSpacing: value)),
          ),
          _slider(
            label: '左右边距 ${_draft.horizontalPadding.toStringAsFixed(0)}',
            value: _draft.horizontalPadding,
            min: 8,
            max: 48,
            divisions: 20,
            onChanged: (double value) => _update(_draft.copyWith(horizontalPadding: value)),
          ),
          const SizedBox(height: SpacingToken.small),
          const Text('阅读配色'),
          Wrap(
            spacing: SpacingToken.small,
            children: <Widget>[
              _colorChoice('纸张', 0xFFFFFBF2, 0xFF2B2925),
              _colorChoice('护眼', 0xFFE7F0DB, 0xFF263322),
              _colorChoice('深色', 0xFF171A17, 0xFFDDE5DA),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _draft.useReplaceRules,
            title: const Text('应用替换规则'),
            subtitle: const Text('关闭后从原始正文缓存重新生成显示内容'),
            onChanged: (bool value) => _update(_draft.copyWith(useReplaceRules: value)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _draft.keepScreenOn,
            title: const Text('阅读时保持屏幕常亮'),
            onChanged: (bool value) => _update(_draft.copyWith(keepScreenOn: value)),
          ),
          const SizedBox(height: SpacingToken.medium),
          FilledButton(
            onPressed: () => widget.onApply(_draft),
            child: const Text('应用'),
          ),
        ],
      ),
    );
  }

  /// 构建带标签的显示配置滑杆。
  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// 构建一个背景与文字颜色组合选项。
  Widget _colorChoice(String label, int background, int foreground) {
    /// 当前是否选择该配色。
    final bool selected = _draft.backgroundColorValue == background &&
        _draft.textColorValue == foreground;
    return ChoiceChip(
      selected: selected,
      avatar: CircleAvatar(backgroundColor: Color(background)),
      label: Text(label),
      onSelected: (bool value) {
        if (value) {
          _update(
            _draft.copyWith(
              backgroundColorValue: background,
              textColorValue: foreground,
            ),
          );
        }
      },
    );
  }

  /// 更新本地草稿并刷新面板控件。
  void _update(ReaderDisplayConfig config) {
    setState(() {
      _draft = config;
    });
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
          const ListTile(title: Text('书签')),
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
                        trailing: IconButton(
                          onPressed: () => onIntent(DeleteReaderBookmarkIntent(bookmark)),
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '删除书签',
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
