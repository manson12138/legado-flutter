import 'package:flutter/material.dart';

import '../../domain/model/book.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';
import 'reader_contract.dart';

/// 首次打开一本书时展示的第 0 页，在正文准备完成前保留书籍信息和简介。
final class ReaderIntroPage extends StatefulWidget {
  /// 创建首次阅读先导页。
  const ReaderIntroPage({
    required this.state,
    required this.onAttemptEnter,
    required this.onRetry,
    required this.onBack,
    super.key,
  });

  /// 当前阅读器状态，用于展示书籍、章节和正文就绪状态。
  final ReaderUiState state;

  /// 左滑或点击按钮时尝试进入正文。
  final VoidCallback onAttemptEnter;

  /// 正文或初始化失败后的重试动作。
  final VoidCallback onRetry;

  /// 只查看先导页后返回，不写已看标记。
  final VoidCallback onBack;

  /// 创建只持有一次手势位移的轻量状态。
  @override
  State<ReaderIntroPage> createState() => _ReaderIntroPageState();
}

/// 累计单次水平手势距离，不持有控制器、订阅、Timer 或图片对象。
final class _ReaderIntroPageState extends State<ReaderIntroPage> {
  /// 当前手势累计水平位移，负数表示向正文方向左滑。
  double _horizontalDragDistance = 0;

  /// 新手势开始时清空上一次位移。
  void _handleHorizontalDragStart(DragStartDetails details) {
    _horizontalDragDistance = 0;
  }

  /// 累计本次水平位移，不触发 setState，避免手势每帧重建页面。
  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    _horizontalDragDistance += details.delta.dx;
  }

  /// 达到距离或速度阈值时只发送一次进入尝试，正文未就绪由 ViewModel 节流提示。
  void _handleHorizontalDragEnd(DragEndDetails details) {
    /// 松手时的水平速度，负数表示向左。
    final double velocity = details.primaryVelocity ?? 0;
    if (_horizontalDragDistance <= -36 || velocity <= -260) {
      widget.onAttemptEnter();
    }
    _horizontalDragDistance = 0;
  }

  /// 构建上部封面、中部元信息、下部简介和底部进入动作。
  @override
  Widget build(BuildContext context) {
    /// 当前可用书籍快照。
    final Book? book = widget.state.book;
    /// 阅读配置前景色。
    final Color textColor = Color(widget.state.config.textColorValue);
    /// 正文已经具备可展示内容。
    final bool contentReady =
        widget.state.loadState == ReaderLoadState.ready &&
        widget.state.content != null;
    /// 当前章节优先使用完整目录，其次使用书籍快照保存的标题。
    final String chapterTitle =
        widget.state.currentChapter?.title ??
        book?.durChapterTitle?.trim() ??
        '';
    /// 目录尚未完成时仍可使用书籍快照中的总章节数。
    final int totalChapterCount = widget.state.chapters.isNotEmpty
        ? widget.state.chapters.length
        : book?.totalChapterNum ?? 0;
    /// 自定义简介优先于书源简介，空白值不覆盖有效简介。
    final String customIntro = book?.customIntro?.trim() ?? '';
    final String sourceIntro = book?.intro?.trim() ?? '';
    final String intro = customIntro.isNotEmpty
        ? customIntro
        : sourceIntro.isNotEmpty
        ? sourceIntro
        : '暂无书籍简介';
    /// 首选自定义封面，其次使用书源封面。
    final String? coverUrl = book?.customCoverUrl ?? book?.coverUrl;
    /// 当前加载阶段对应的非动画状态文案。
    final String statusMessage = switch (widget.state.loadState) {
      ReaderLoadState.error =>
        widget.state.errorMessage ?? '本章暂时无法打开',
      ReaderLoadState.ready => '左滑或点击下方按钮开始阅读',
      ReaderLoadState.initializing => '正在恢复目录和阅读位置',
      ReaderLoadState.loading => '正在准备本章内容',
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _handleHorizontalDragStart,
      onHorizontalDragUpdate: _handleHorizontalDragUpdate,
      onHorizontalDragEnd: _handleHorizontalDragEnd,
      child: Column(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                SpacingToken.large,
                SpacingToken.large,
                SpacingToken.large,
                SpacingToken.medium,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Center(
                        child: RepaintBoundary(
                          child: SizedBox(
                            width: 132,
                            height: 188,
                            child: BookCover(
                              coverUrl: coverUrl,
                              semanticLabel: '${book?.name ?? '目标书籍'}封面',
                              bookName: book?.name,
                              bookAuthor: book?.author,
                              borderRadius: const BorderRadius.all(
                                Radius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: SpacingToken.large),
                      Text(
                        book?.name.trim().isNotEmpty == true
                            ? book?.name ?? '正在准备阅读'
                            : '正在准备阅读',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: textColor,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      if (book?.author.trim().isNotEmpty == true) ...<Widget>[
                        const SizedBox(height: SpacingToken.small),
                        Text(
                          book?.author ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: textColor.withValues(alpha: 0.72),
                              ),
                        ),
                      ],
                      const SizedBox(height: SpacingToken.large),
                      _ReaderIntroMetadata(
                        chapterTitle: chapterTitle,
                        chapterIndex: widget.state.currentChapterIndex,
                        totalChapterCount: totalChapterCount,
                        sourceName: book?.originName ?? '',
                        textColor: textColor,
                      ),
                      const SizedBox(height: SpacingToken.large),
                      Text(
                        '书籍简介',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: textColor,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: SpacingToken.small),
                      Text(
                        intro,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(
                              color: textColor.withValues(alpha: 0.82),
                              height: 1.65,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: textColor.withValues(alpha: 0.12),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                SpacingToken.large,
                SpacingToken.medium,
                SpacingToken.large,
                SpacingToken.large,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      statusMessage,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: widget.state.loadState == ReaderLoadState.error
                            ? Theme.of(context).colorScheme.error
                            : textColor.withValues(alpha: 0.66),
                      ),
                    ),
                  ),
                  const SizedBox(height: SpacingToken.medium),
                  Row(
                    children: <Widget>[
                      OutlinedButton(
                        onPressed: widget.onBack,
                        child: const Text('返回'),
                      ),
                      const SizedBox(width: SpacingToken.medium),
                      Expanded(
                        child: widget.state.loadState == ReaderLoadState.error
                            ? FilledButton.icon(
                                onPressed: widget.onRetry,
                                icon: const Icon(Icons.refresh),
                                label: const Text('重试'),
                              )
                            : FilledButton(
                                onPressed: widget.onAttemptEnter,
                                child: Text(
                                  contentReady ? '开始阅读' : '正在准备本章',
                                ),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 展示当前章节、章节序号和书源，不参与正文加载或持久化。
final class _ReaderIntroMetadata extends StatelessWidget {
  /// 创建先导页元信息区。
  const _ReaderIntroMetadata({
    required this.chapterTitle,
    required this.chapterIndex,
    required this.totalChapterCount,
    required this.sourceName,
    required this.textColor,
  });

  /// 目标章节标题。
  final String chapterTitle;

  /// 目标章节从零开始的原始目录索引。
  final int chapterIndex;

  /// 当前已知目录总数。
  final int totalChapterCount;

  /// 当前书源名称。
  final String sourceName;

  /// 跟随阅读配置的前景色。
  final Color textColor;

  /// 构建可自动换行的元信息标签。
  @override
  Widget build(BuildContext context) {
    /// 有效章节序号，目录未就绪时不展示虚假的第一章。
    final String chapterProgress = totalChapterCount > 0
        ? '第 ${chapterIndex + 1} / $totalChapterCount 章'
        : '章节信息准备中';
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: SpacingToken.small,
      runSpacing: SpacingToken.small,
      children: <Widget>[
        _ReaderIntroMetadataChip(
          label: chapterProgress,
          textColor: textColor,
        ),
        if (chapterTitle.trim().isNotEmpty)
          _ReaderIntroMetadataChip(
            label: chapterTitle.trim(),
            textColor: textColor,
          ),
        if (sourceName.trim().isNotEmpty)
          _ReaderIntroMetadataChip(
            label: sourceName.trim(),
            textColor: textColor,
          ),
      ],
    );
  }
}

/// 先导页轻量元信息标签。
final class _ReaderIntroMetadataChip extends StatelessWidget {
  /// 创建元信息标签。
  const _ReaderIntroMetadataChip({
    required this.label,
    required this.textColor,
  });

  /// 标签文字。
  final String label;

  /// 跟随阅读配置的前景色。
  final Color textColor;

  /// 构建不产生阴影和模糊的圆角标签。
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpacingToken.medium,
          vertical: SpacingToken.small,
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: textColor.withValues(alpha: 0.78),
          ),
        ),
      ),
    );
  }
}
