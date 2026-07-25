import 'package:flutter/material.dart';

/// 书架目的地中按横滑进度显示的固定双页页签。
final class BookshelfPageSwitcher extends StatelessWidget {
  /// 创建书架和历史页签。
  const BookshelfPageSwitcher({
    required this.pageProgress,
    required this.onSelected,
    super.key,
  });

  /// 当前从书架（0）到历史（1）的手势动画进度。
  final double pageProgress;

  /// 用户点击目标页签后的回调。
  final ValueChanged<int> onSelected;

  /// 构建随手势连续过渡字号的纯文字页签。
  @override
  Widget build(BuildContext context) {
    /// 将横滑进度限制为两个页签之间的有效区间。
    final double progress = pageProgress.clamp(0.0, 1.0);
    /// 书架文字从选中字号平滑缩小到未选中字。
    final double bookshelfFontSize = 20 - 3 * progress;
    /// 历史文字从未选中字平滑放大到选中字号。
    final double historyFontSize = 17 + 3 * progress;
    return SizedBox(
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _PageSegment(
            label: '书架',
            emphasis: 1 - progress,
            fontSize: bookshelfFontSize,
            onPressed: () => onSelected(0),
          ),
          const SizedBox(width: 16),
          _PageSegment(
            label: '历史',
            emphasis: progress,
            fontSize: historyFontSize,
            onPressed: () => onSelected(1),
          ),
        ],
      ),
    );
  }
}

/// 单个纯文字页签，仅承载点击反馈和由路由提供的字号过渡。
final class _PageSegment extends StatelessWidget {
  /// 创建书架或历史页签。
  const _PageSegment({
    required this.label,
    required this.emphasis,
    required this.fontSize,
    required this.onPressed,
  });

  /// 页签文字。
  final String label;
  /// 当前页签的强调程度，范围为 0 到 1。
  final double emphasis;
  /// 当前页签随横滑进度变化的文字字号。
  final double fontSize;
  /// 切换目标页的回调。
  final VoidCallback onPressed;

  /// 构建无图标、无背景的文字页签。
  @override
  Widget build(BuildContext context) {
    /// 使用颜色插值，使文字强调状态与字号同步平滑切换。
    final Color color = Color.lerp(
          Theme.of(context).colorScheme.onSurfaceVariant,
          Theme.of(context).colorScheme.primary,
          emphasis,
        ) ??
        Theme.of(context).colorScheme.primary;
    return TextButton(
        style: TextButton.styleFrom(
          foregroundColor: color,
          padding: EdgeInsets.zero,
          minimumSize: const Size(48, 40),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
    );
  }
}
