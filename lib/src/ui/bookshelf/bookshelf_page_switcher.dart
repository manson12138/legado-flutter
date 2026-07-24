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

  /// 构建矩形页签和随手势移动的选中背景。
  @override
  Widget build(BuildContext context) {
    final Color baseColor = Theme.of(context).colorScheme.secondaryContainer;
    final double progress = pageProgress.clamp(0.0, 1.0);
    return SizedBox(
      height: 40,
      width: 184,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double segmentWidth = constraints.maxWidth / 2;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: <Color>[baseColor, baseColor.withValues(alpha: 0)],
              ),
            ),
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: segmentWidth * progress,
                  top: 0,
                  bottom: 0,
                  width: segmentWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: <Color>[
                          Theme.of(context).colorScheme.primaryContainer,
                          Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
                Row(
                  children: <Widget>[
                    _PageSegment(
                      icon: Icons.auto_stories_outlined,
                      label: '书架',
                      selected: progress < 0.5,
                      onPressed: () => onSelected(0),
                    ),
                    _PageSegment(
                      icon: Icons.history,
                      label: '历史',
                      selected: progress >= 0.5,
                      onPressed: () => onSelected(1),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 单个页签按钮，仅承载点击反馈和由路由提供的选中显示。
final class _PageSegment extends StatelessWidget {
  /// 创建书架或历史页签。
  const _PageSegment({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  /// 页签图标。
  final IconData icon;
  /// 页签文字。
  final String label;
  /// 是否按当前拖动进度显示为选中。
  final bool selected;
  /// 切换目标页的回调。
  final VoidCallback onPressed;

  /// 构建无圆角描边的矩形页签。
  @override
  Widget build(BuildContext context) {
    final Color color = selected
        ? Theme.of(context).colorScheme.onPrimaryContainer
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Expanded(
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: color,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }
}
