import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';

import '../../domain/model/book_content_process.dart';

/// 为连续和分页阅读正文提供 Flutter 原生拖动选区及自定义业务菜单。
final class ReaderSelectionRegion extends StatefulWidget {
  /// 创建限制在指定章节字符范围内的可选择区域。
  const ReaderSelectionRegion({
    required this.chapterText,
    required this.scopeStart,
    required this.scopeEnd,
    required this.preferredOffset,
    required this.selectionEpoch,
    required this.onAction,
    required this.child,
    super.key,
  });

  /// 当前处理完成的完整章节正文。
  final String chapterText;

  /// 当前区域在完整正文中的起始字符位置。
  final int scopeStart;

  /// 当前区域在完整正文中的结束字符位置，不包含该位置字符。
  final int scopeEnd;

  /// 出现重复文本时优先靠近的当前阅读位置。
  final int preferredOffset;

  /// 翻页、切章或正文刷新时递增，用于主动清除旧选区。
  final int selectionEpoch;

  /// 用户从选区菜单选择书签、高亮或下划线后的业务回调。
  final void Function(
    ReaderTextSelection selection,
    ReaderSelectionAction action,
  ) onAction;

  /// 包含一个或多个 Text 的实际正文布局。
  final Widget child;

  /// 创建保存当前选择文本的局部状态。
  @override
  State<ReaderSelectionRegion> createState() =>
      _ReaderSelectionRegionState();
}

/// 仅保存 Flutter 选择生命周期，不持久化业务标注。
final class _ReaderSelectionRegionState extends State<ReaderSelectionRegion> {
  /// Flutter 当前选择区域返回的纯文本。
  String _selectedText = '';

  /// 外部翻页或切章后清除已经失效的局部选择文本。
  @override
  void didUpdateWidget(covariant ReaderSelectionRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectionEpoch != widget.selectionEpoch ||
        oldWidget.chapterText != widget.chapterText) {
      _selectedText = '';
    }
  }

  /// 构建原生选择手柄、放大镜和自定义上下文菜单。
  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      key: ValueKey<String>(
        '${widget.selectionEpoch}:${widget.scopeStart}:${widget.scopeEnd}',
      ),
      onSelectionChanged: (SelectedContent? content) {
        _selectedText = content?.plainText ?? '';
      },
      contextMenuBuilder: (
        BuildContext menuContext,
        SelectableRegionState selectableRegionState,
      ) {
        /// Flutter 按当前平台提供的复制、全选和分享按钮。
        final List<ContextMenuButtonItem> buttons = selectableRegionState
            .contextMenuButtonItems
            .map((ContextMenuButtonItem item) {
              if (item.type != ContextMenuButtonType.copy) {
                return item;
              }
              return item.copyWith(
                onPressed: () => _copySelection(selectableRegionState),
              );
            })
            .toList(growable: true);
        buttons.addAll(<ContextMenuButtonItem>[
          ContextMenuButtonItem(
            label: '书签',
            onPressed: () => _applyAction(
              selectableRegionState,
              ReaderSelectionAction.bookmark,
            ),
          ),
          ContextMenuButtonItem(
            label: '高亮',
            onPressed: () => _applyAction(
              selectableRegionState,
              ReaderSelectionAction.highlight,
            ),
          ),
          ContextMenuButtonItem(
            label: '下划线',
            onPressed: () => _applyAction(
              selectableRegionState,
              ReaderSelectionAction.underline,
            ),
          ),
        ]);
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: selectableRegionState.contextMenuAnchors,
          buttonItems: buttons,
        );
      },
      child: widget.child,
    );
  }

  /// 复制映射回章节的可信原文，排除分页换行和显示用全角缩进。
  void _copySelection(SelectableRegionState selectableRegionState) {
    /// 当前选择对应的稳定章节范围。
    final ReaderTextSelection? selection = _resolveSelection();
    if (selection == null) {
      selectableRegionState.clearSelection();
      _selectedText = '';
      return;
    }
    Clipboard.setData(ClipboardData(text: selection.text));
    selectableRegionState.clearSelection();
    _selectedText = '';
  }

  /// 把 Flutter 选择纯文本解析为稳定字符范围并发送业务动作。
  void _applyAction(
    SelectableRegionState selectableRegionState,
    ReaderSelectionAction action,
  ) {
    /// 当前选择对应的稳定章节范围。
    final ReaderTextSelection? selection = _resolveSelection();
    selectableRegionState.clearSelection();
    _selectedText = '';
    if (selection == null) {
      return;
    }
    widget.onAction(selection, action);
  }

  /// 在当前区域内查找最接近阅读位置的选区文本，忽略显示缩进和布局换行差异。
  ReaderTextSelection? _resolveSelection() {
    if (_selectedText.trim().isEmpty || widget.chapterText.isEmpty) {
      return null;
    }
    /// 收窄到当前区域和完整正文交集后的起点。
    final int scopeStart = widget.scopeStart
        .clamp(0, widget.chapterText.length)
        .toInt();
    /// 收窄到当前区域和完整正文交集后的终点。
    final int scopeEnd = widget.scopeEnd
        .clamp(scopeStart, widget.chapterText.length)
        .toInt();
    if (scopeEnd <= scopeStart) {
      return null;
    }
    /// 当前选择区域对应的原始正文。
    final String scopeText = widget.chapterText.substring(scopeStart, scopeEnd);
    /// 精确选择文本在区域内最接近阅读位置的候选。
    final int exactLocalStart = _closestOccurrence(
      scopeText,
      _selectedText,
      widget.preferredOffset - scopeStart,
    );
    if (exactLocalStart >= 0) {
      /// 精确候选在完整章节中的起点。
      final int exactStart = scopeStart + exactLocalStart;
      return ReaderTextSelection(
        start: exactStart,
        end: exactStart + _selectedText.length,
        text: widget.chapterText.substring(
          exactStart,
          exactStart + _selectedText.length,
        ),
      );
    }
    /// 去除布局缩进和换行后的区域正文映射。
    final _ReaderSelectionNormalizedText normalizedScope =
        _normalizeSelectionText(scopeText);
    /// 去除布局缩进和换行后的选择文本。
    final String normalizedSelection =
        _normalizeSelectionText(_selectedText).text;
    if (normalizedSelection.isEmpty) {
      return null;
    }
    /// 规范化选择文本在区域内的候选位置。
    final int normalizedStart = _closestOccurrence(
      normalizedScope.text,
      normalizedSelection,
      widget.preferredOffset - scopeStart,
    );
    if (normalizedStart < 0 ||
        normalizedStart + normalizedSelection.length >
            normalizedScope.sourceIndices.length) {
      return null;
    }
    /// 规范化候选映射回完整章节后的起点。
    final int sourceStart = scopeStart +
        normalizedScope.sourceIndices[normalizedStart];
    /// 规范化候选映射回完整章节后的终点。
    final int sourceEnd = scopeStart +
        normalizedScope.sourceIndices[
            normalizedStart + normalizedSelection.length - 1] +
        1;
    return ReaderTextSelection(
      start: sourceStart,
      end: sourceEnd,
      text: widget.chapterText.substring(sourceStart, sourceEnd),
    );
  }
}

/// 保存选择匹配使用的无空白文本及原文字符位置。
final class _ReaderSelectionNormalizedText {
  /// 创建选择文本规范化映射。
  const _ReaderSelectionNormalizedText({
    required this.text,
    required this.sourceIndices,
  });

  /// 去除普通和全角空白后的文本。
  final String text;

  /// 每个规范化字符在原文中的位置。
  final List<int> sourceIndices;
}

/// 去除选择匹配不关心的空白和显示缩进，并保留原文位置。
_ReaderSelectionNormalizedText _normalizeSelectionText(String source) {
  /// 规范化选择文本缓冲区。
  final StringBuffer output = StringBuffer();
  /// 每个保留字符在原文中的位置。
  final List<int> sourceIndices = <int>[];
  for (int index = 0; index < source.length; index += 1) {
    /// 当前待判断的 UTF-16 字符。
    final String character = source[index];
    if (character.trim().isEmpty || character == '　') {
      continue;
    }
    output.write(character);
    sourceIndices.add(index);
  }
  return _ReaderSelectionNormalizedText(
    text: output.toString(),
    sourceIndices: List<int>.unmodifiable(sourceIndices),
  );
}

/// 在重复文本中返回最接近参考位置的候选起点。
int _closestOccurrence(String content, String pattern, int preferredOffset) {
  /// 首个候选位置。
  int match = content.indexOf(pattern);
  if (match < 0) {
    return -1;
  }
  /// 当前最接近参考位置的候选。
  int closest = match;
  /// 当前最短距离。
  int closestDistance = (match - preferredOffset).abs();
  while (match >= 0) {
    /// 当前候选与参考位置的距离。
    final int distance = (match - preferredOffset).abs();
    if (distance < closestDistance) {
      closest = match;
      closestDistance = distance;
    }
    match = content.indexOf(pattern, match + 1);
  }
  return closest;
}

/// 为一个与正文字符范围一一对应的文本片段生成高亮和下划线 Span。
List<InlineSpan> buildReaderAnnotationSpans({
  required String chapterText,
  required String text,
  required int startOffset,
  required TextStyle baseStyle,
  required List<BookContentProcess> processes,
}) {
  if (text.isEmpty || processes.isEmpty) {
    return <InlineSpan>[TextSpan(text: text, style: baseStyle)];
  }
  /// 当前文本片段在完整正文中的终点。
  final int endOffset = startOffset + text.length;
  /// 所有标注交界点，用于把文本拆成具有单一样式的最小片段。
  final Set<int> boundaries = <int>{startOffset, endOffset};
  /// 当前文本片段实际相交的标注和稳定范围。
  final List<({BookContentProcess process, ReaderTextRange range})>
      applicable = <({BookContentProcess process, ReaderTextRange range})>[];
  for (final BookContentProcess process in processes) {
    /// 当前标注在最新正文中的稳定范围。
    final ReaderTextRange? range = process.resolveRange(chapterText);
    if (range == null || range.end <= startOffset || range.start >= endOffset) {
      continue;
    }
    /// 当前片段内的标注起点。
    final int clippedStart = range.start.clamp(startOffset, endOffset).toInt();
    /// 当前片段内的标注终点。
    final int clippedEnd = range.end.clamp(startOffset, endOffset).toInt();
    boundaries
      ..add(clippedStart)
      ..add(clippedEnd);
    applicable.add((process: process, range: range));
  }
  if (applicable.isEmpty) {
    return <InlineSpan>[TextSpan(text: text, style: baseStyle)];
  }
  /// 按正文顺序排列的标注交界点。
  final List<int> orderedBoundaries = boundaries.toList()..sort();
  /// 最终可绘制的带样式文本片段。
  final List<InlineSpan> spans = <InlineSpan>[];
  for (int index = 0; index < orderedBoundaries.length - 1; index += 1) {
    /// 当前最小片段在完整正文中的起点。
    final int segmentStart = orderedBoundaries[index];
    /// 当前最小片段在完整正文中的终点。
    final int segmentEnd = orderedBoundaries[index + 1];
    if (segmentEnd <= segmentStart) {
      continue;
    }
    /// 覆盖当前最小片段的全部标注。
    final List<BookContentProcess> segmentProcesses = applicable
        .where((entry) =>
            entry.range.start < segmentEnd && entry.range.end > segmentStart)
        .map((entry) => entry.process)
        .toList(growable: false);
    /// 当前片段最后设置的背景高亮颜色。
    int? backgroundColorValue;
    /// 当前片段最后设置的下划线颜色。
    int? underlineColorValue;
    for (final BookContentProcess process in segmentProcesses) {
      backgroundColorValue =
          process.style.backgroundColorValue ?? backgroundColorValue;
      underlineColorValue =
          process.style.underlineColorValue ?? underlineColorValue;
    }
    /// 合并基础排版与用户标注后的样式。
    final TextStyle segmentStyle = baseStyle.copyWith(
      backgroundColor: backgroundColorValue == null
          ? baseStyle.backgroundColor
          : Color(backgroundColorValue),
      decoration: underlineColorValue == null
          ? baseStyle.decoration
          : TextDecoration.underline,
      decorationColor: underlineColorValue == null
          ? baseStyle.decorationColor
          : Color(underlineColorValue),
      decorationThickness: underlineColorValue == null ? null : 1.5,
    );
    spans.add(
      TextSpan(
        text: text.substring(
          segmentStart - startOffset,
          segmentEnd - startOffset,
        ),
        style: segmentStyle,
      ),
    );
  }
  return spans;
}
