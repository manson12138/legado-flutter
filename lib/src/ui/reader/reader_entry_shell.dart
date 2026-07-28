import 'package:flutter/material.dart';

import '../../domain/model/book.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';

/// 在正文首个可读页面形成前展示书籍事实，替代没有业务含义的全屏转圈。
final class ReaderEntryShell extends StatelessWidget {
  /// 创建阅读恢复或错误壳；按钮为空时只展示非阻断状态。
  const ReaderEntryShell({
    required this.book,
    required this.chapterTitle,
    required this.statusMessage,
    required this.textColor,
    this.errorMessage,
    this.onRetry,
    this.onBack,
    super.key,
  });

  /// 路由或数据库已经提供的书籍快照。
  final Book? book;

  /// 当前计划恢复的章节标题；目录未就绪时允许为空。
  final String chapterTitle;

  /// 当前本地恢复或正文准备阶段的简短说明。
  final String statusMessage;

  /// 跟随阅读显示配置的前景色。
  final Color textColor;

  /// 可向用户展示的受控错误摘要。
  final String? errorMessage;

  /// 错误后的重试动作。
  final VoidCallback? onRetry;

  /// 放弃恢复并关闭阅读器的动作。
  final VoidCallback? onBack;

  /// 构建不含无限动画、可适配大字体和小屏幕的阅读入口壳。
  @override
  Widget build(BuildContext context) {
    /// 当前可用书籍快照。
    final Book? currentBook = book;
    /// 首选自定义封面，其次使用书源封面。
    final String? coverUrl =
        currentBook?.customCoverUrl ?? currentBook?.coverUrl;
    /// 目录未就绪时使用书籍保存的最近章节标题。
    final String effectiveChapterTitle = chapterTitle.trim().isNotEmpty
        ? chapterTitle.trim()
        : currentBook?.durChapterTitle?.trim() ?? '';
    /// 错误存在时让辅助功能优先读出错误，否则读出恢复状态。
    final String liveMessage = errorMessage ?? statusMessage;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(SpacingToken.large),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              RepaintBoundary(
                child: SizedBox(
                  width: 112,
                  height: 160,
                  child: BookCover(
                    coverUrl: coverUrl,
                    semanticLabel: '${currentBook?.name ?? '目标书籍'}封面',
                    bookName: currentBook?.name,
                    bookAuthor: currentBook?.author,
                    borderRadius: const BorderRadius.all(Radius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: SpacingToken.large),
              Text(
                currentBook?.name.trim().isNotEmpty == true
                    ? currentBook?.name ?? '正在准备阅读'
                    : '正在准备阅读',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: textColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (currentBook?.author.trim().isNotEmpty == true) ...<Widget>[
                const SizedBox(height: SpacingToken.small),
                Text(
                  currentBook?.author ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: textColor.withValues(alpha: 0.72),
                  ),
                ),
              ],
              if (effectiveChapterTitle.isNotEmpty) ...<Widget>[
                const SizedBox(height: SpacingToken.medium),
                Text(
                  effectiveChapterTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: textColor.withValues(alpha: 0.86),
                  ),
                ),
              ],
              const SizedBox(height: SpacingToken.large),
              Semantics(
                liveRegion: true,
                child: Text(
                  liveMessage,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: errorMessage == null
                        ? textColor.withValues(alpha: 0.68)
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
              if (onRetry != null || onBack != null) ...<Widget>[
                const SizedBox(height: SpacingToken.large),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: SpacingToken.medium,
                  runSpacing: SpacingToken.small,
                  children: <Widget>[
                    if (onBack != null)
                      OutlinedButton(
                        onPressed: onBack,
                        child: const Text('返回'),
                      ),
                    if (onRetry != null)
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
