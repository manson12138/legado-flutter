import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/model/reader_content.dart';
import '../theme/app_tokens.dart';
import 'reader_contract.dart';

/// 标记分页行使用章节标题、正文或仅占据垂直空间。
enum ReaderPageLineKind {
  /// 第一页章节标题行。
  title,

  /// 参与阅读进度计算的正文行。
  body,

  /// 标题或段落之间不参与字符位置计算的垂直间距。
  spacer,
}

/// 保存分页器已经测量完成的一行内容及其稳定正文位置。
final class ReaderPageLine {
  /// 创建不可变分页行。
  const ReaderPageLine({
    required this.kind,
    required this.text,
    required this.height,
    required this.startOffset,
    required this.endOffset,
    this.extraLetterSpacing = 0,
    this.extraWordSpacing = 0,
  });

  /// 当前行的标题、正文或间距类型。
  final ReaderPageLineKind kind;

  /// 当前行实际绘制的文本；间距行固定为空字符串。
  final String text;

  /// 当前行由 TextPainter 测量得到的精确高度。
  final double height;

  /// 当前行在处理后正文中的起始字符位置，标题和间距不改变该位置。
  final int startOffset;

  /// 当前行在处理后正文中的结束字符位置，不包含该位置字符。
  final int endOffset;

  /// 两端对齐时在基础字距之外分配给每个字符间隙的额外距离。
  final double extraLetterSpacing;

  /// 两端对齐时在基础词距之外分配给每个半角空格的额外距离。
  final double extraWordSpacing;
}

/// 保存一页标题、正文排版行和对应的稳定正文字符区间。
final class ReaderTextPage {
  /// 创建不可变正文页。
  ReaderTextPage({
    required this.startOffset,
    required this.endOffset,
    required List<ReaderPageLine> lines,
  }) : lines = List<ReaderPageLine>.unmodifiable(lines);

  /// 当前页在完整处理后正文中的起始字符位置。
  final int startOffset;

  /// 当前页在完整处理后正文中的结束字符位置，不包含该位置字符。
  final int endOffset;

  /// 当前页面按真实字体测量完成的标题、正文和间距行。
  final List<ReaderPageLine> lines;
}

/// 根据当前屏幕、字体和行高把正文切成可稳定恢复的页面。
abstract final class ReaderPageLayoutEngine {
  /// 单次交给 TextPainter 的最大段落字符数，避免无换行长章节一次测量过重。
  static const int _maximumMeasuredParagraphLength = 1200;

  /// 按章节标题、正文段落和真实排版行逐行装页，对应 Android TextChapterLayout。
  static List<ReaderTextPage> paginate({
    required String title,
    required String text,
    required TextStyle bodyStyle,
    required TextStyle titleStyle,
    required double maxWidth,
    required double maxHeight,
    required double titleTopSpacing,
    required double titleBottomSpacing,
    required double paragraphSpacing,
    required int paragraphIndent,
    required bool textFullJustify,
    required TextDirection textDirection,
    required TextScaler textScaler,
    int? maximumPageCount,
    int minimumEndOffset = 0,
  }) {
    if ((title.isEmpty && text.isEmpty) || maxWidth <= 0 || maxHeight <= 0) {
      return const <ReaderTextPage>[];
    }
    /// 最终按正文顺序生成的页面列表。
    final List<ReaderTextPage> pages = <ReaderTextPage>[];
    /// 当前页面已经装入的排版行。
    List<ReaderPageLine> currentLines = <ReaderPageLine>[];
    /// 当前页面已经使用的垂直高度。
    double usedHeight = 0;
    /// 当前页面首个正文字符位置；只有标题时保持为空。
    int? pageStartOffset;
    /// 当前页面正文结束字符位置。
    int pageEndOffset = 0;
    /// 分批分页时是否已经满足首屏可显示页数和目标字符锚点。
    bool reachedPageLimit = false;

    /// 完成当前页并重置逐页累积状态。
    void finishPage() {
      if (currentLines.isEmpty) {
        return;
      }
      pages.add(
        ReaderTextPage(
          startOffset: pageStartOffset ?? pageEndOffset,
          endOffset: pageEndOffset,
          lines: currentLines,
        ),
      );
      currentLines = <ReaderPageLine>[];
      usedHeight = 0;
      pageStartOffset = null;
      if (maximumPageCount != null &&
          pages.length >= maximumPageCount &&
          pageEndOffset >= minimumEndOffset) {
        reachedPageLimit = true;
      }
    }

    /// 将一行加入当前页，放不下时先完成上一页再加入新页。
    void appendLine(ReaderPageLine line) {
      if (reachedPageLimit) {
        return;
      }
      if (currentLines.isNotEmpty && usedHeight + line.height > maxHeight) {
        finishPage();
      }
      if (reachedPageLimit) {
        return;
      }
      currentLines.add(line);
      usedHeight += line.height;
      if (line.kind == ReaderPageLineKind.body && line.endOffset > line.startOffset) {
        pageStartOffset ??= line.startOffset;
        pageEndOffset = line.endOffset;
      }
    }

    /// 在当前页末加入间距；放不下时直接结束页面，下一页不保留顶部空白。
    void appendSpacing(double height) {
      if (height <= 0 || currentLines.isEmpty || reachedPageLimit) {
        return;
      }
      if (usedHeight + height > maxHeight) {
        finishPage();
        return;
      }
      appendLine(
        ReaderPageLine(
          kind: ReaderPageLineKind.spacer,
          text: '',
          height: height,
          startOffset: pageEndOffset,
          endOffset: pageEndOffset,
        ),
      );
    }

    if (title.isNotEmpty) {
      if (titleTopSpacing > 0 && titleTopSpacing < maxHeight) {
        currentLines.add(
          ReaderPageLine(
            kind: ReaderPageLineKind.spacer,
            text: '',
            height: titleTopSpacing,
            startOffset: 0,
            endOffset: 0,
          ),
        );
        usedHeight += titleTopSpacing;
      }
      /// 已按标题样式测量得到的标题行。
      final List<ReaderPageLine> titleLines = _measureLines(
        text: title,
        style: titleStyle,
        kind: ReaderPageLineKind.title,
        sourceStartOffset: 0,
        syntheticPrefixLength: 0,
        includeTrailingOffset: false,
        maxWidth: maxWidth,
        textDirection: textDirection,
        textScaler: textScaler,
        textFullJustify: false,
      );
      for (final ReaderPageLine line in titleLines) {
        appendLine(line);
      }
      appendSpacing(titleBottomSpacing);
    }

    /// 正文段落列表；正文处理器已经移除空段，因此每项都是可显示段落。
    final List<String> paragraphs = text.split('\n');
    /// 当前段落在完整正文中的起始字符位置。
    int paragraphStartOffset = 0;
    for (int index = 0; index < paragraphs.length; index += 1) {
      if (reachedPageLimit) {
        break;
      }
      /// 当前需要排版的原始正文段落。
      final String paragraph = paragraphs[index];
      /// 当前段落之后是否存在一个真实换行字符。
      final bool hasTrailingNewline = index < paragraphs.length - 1;
      /// 当前段落被拆成的测量片段，避免单个无换行长段落阻塞首屏。
      final List<String> chunks = _paragraphChunks(paragraph);
      /// 当前片段在本段落内的原始字符起点。
      int chunkStartOffset = 0;
      for (int chunkIndex = 0; chunkIndex < chunks.length; chunkIndex += 1) {
        /// 当前待测量片段。
        final String chunk = chunks[chunkIndex];
        /// 当前片段是否是段落第一段，用于决定是否显示首行缩进。
        final bool isFirstChunk = chunkIndex == 0;
        /// 当前片段是否是段落最后一段，用于决定是否计入真实换行。
        final bool isLastChunk = chunkIndex == chunks.length - 1;
        /// 只用于显示、不进入正文锚点的全角首行缩进。
        final String indent = isFirstChunk
            ? List<String>.filled(paragraphIndent, '　').join()
            : '';
        /// 当前片段交给 TextPainter 的显示文本。
        final String displayParagraph = '$indent$chunk';
        /// 当前片段按正文样式测量得到的实际行。
        final List<ReaderPageLine> paragraphLines = _measureLines(
          text: displayParagraph,
          style: bodyStyle,
          kind: ReaderPageLineKind.body,
          sourceStartOffset: paragraphStartOffset + chunkStartOffset,
          syntheticPrefixLength: indent.length,
          includeTrailingOffset: hasTrailingNewline && isLastChunk,
          maxWidth: maxWidth,
          textDirection: textDirection,
          textScaler: textScaler,
          textFullJustify: textFullJustify,
        );
        for (final ReaderPageLine line in paragraphLines) {
          appendLine(line);
          if (reachedPageLimit) {
            break;
          }
        }
        if (reachedPageLimit) {
          break;
        }
        chunkStartOffset += chunk.length;
      }
      appendSpacing(paragraphSpacing);
      paragraphStartOffset += paragraph.length + (hasTrailingNewline ? 1 : 0);
    }
    finishPage();
    return pages;
  }

  /// 使用一次 TextPainter 布局提取真实行边界，避免按整章子字符串反复二分测量。
  static List<ReaderPageLine> _measureLines({
    required String text,
    required TextStyle style,
    required ReaderPageLineKind kind,
    required int sourceStartOffset,
    required int syntheticPrefixLength,
    required bool includeTrailingOffset,
    required double maxWidth,
    required TextDirection textDirection,
    required TextScaler textScaler,
    required bool textFullJustify,
  }) {
    if (text.isEmpty) {
      return const <ReaderPageLine>[];
    }
    /// 当前标题或段落的 Flutter 文本布局器。
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    /// 当前布局产生的真实行高列表。
    final metrics = painter.computeLineMetrics();
    /// 最终转换为阅读分页行的结果。
    final List<ReaderPageLine> lines = <ReaderPageLine>[];
    /// 下一次查询行边界使用的文本位置。
    int probeOffset = 0;
    for (int index = 0; index < metrics.length; index += 1) {
      /// 当前行对应的原始文本边界。
      final range = painter.getLineBoundary(
        TextPosition(offset: probeOffset.clamp(0, text.length).toInt()),
      );
      /// 去掉显式换行后的当前显示行文本。
      final String lineText = _trimTrailingLineBreak(text.substring(range.start, range.end));
      /// 排除显示缩进后映射到正文段落内的起始位置。
      final int localStart = (range.start - syntheticPrefixLength)
          .clamp(0, text.length - syntheticPrefixLength)
          .toInt();
      /// 排除显示缩进后映射到正文段落内的结束位置。
      final int localEnd = (range.end - syntheticPrefixLength)
          .clamp(0, text.length - syntheticPrefixLength)
          .toInt();
      /// 当前行是否是段落最后一行。
      final bool isLastLine = index == metrics.length - 1;
      /// 当前行除去基础排版后尚需分配的水平距离。
      final double remainingWidth = (maxWidth - metrics[index].width).clamp(0, maxWidth);
      /// 当前显示行中的半角空格数量，英文段落优先通过词距分配剩余宽度。
      final int spaceCount = ' '.allMatches(lineText).length;
      /// 当前显示行按 Unicode 码点计算的字符间隙数量。
      final int characterGapCount = lineText.runes.length - 1;
      /// 当前行需要增加的字符间距；段落末行保持自然宽度。
      final double extraLetterSpacing = textFullJustify &&
              !isLastLine &&
              spaceCount <= 1 &&
              characterGapCount > 0
          ? remainingWidth / characterGapCount
          : 0;
      /// 当前行需要增加的词距；包含多个空格时避免拉散英文单词内部字符。
      final double extraWordSpacing = textFullJustify &&
              !isLastLine &&
              spaceCount > 1
          ? remainingWidth / spaceCount
          : 0;
      /// 当前行映射回完整正文后的结束位置。
      final int endOffset = sourceStartOffset + localEnd +
          (includeTrailingOffset && isLastLine ? 1 : 0);
      lines.add(
        ReaderPageLine(
          kind: kind,
          text: lineText,
          height: metrics[index].height,
          startOffset: sourceStartOffset + localStart,
          endOffset: endOffset,
          extraLetterSpacing: extraLetterSpacing,
          extraWordSpacing: extraWordSpacing,
        ),
      );
      if (range.end <= probeOffset) {
        probeOffset += 1;
      } else {
        probeOffset = range.end;
      }
    }
    painter.dispose();
    return lines;
  }

  /// 只移除 TextPainter 行边界末尾的换行符，不改变正文其余空白。
  static String _trimTrailingLineBreak(String value) {
    if (value.endsWith('\r\n')) {
      return value.substring(0, value.length - 2);
    }
    if (value.endsWith('\n') || value.endsWith('\r')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }

  /// 将无换行超长段落拆成有限片段，降低首屏和后台分页的单次测量成本。
  static List<String> _paragraphChunks(String paragraph) {
    if (paragraph.length <= _maximumMeasuredParagraphLength) {
      return <String>[paragraph];
    }
    /// 拆分后的段落测量片段。
    final List<String> chunks = <String>[];
    for (int start = 0; start < paragraph.length; start += _maximumMeasuredParagraphLength) {
      /// 当前片段结束位置。
      final int end = (start + _maximumMeasuredParagraphLength)
          .clamp(0, paragraph.length)
          .toInt();
      chunks.add(paragraph.substring(start, end));
    }
    return chunks;
  }
}

/// 缓存最近章节的完整分页结果，避免长章节在组件重建或返回阅读时重复测量。
abstract final class ReaderPageLayoutCache {
  /// 最多保留的分页结果数量，限制长章节缓存占用。
  static const int _maximumEntryCount = 3;

  /// 按访问顺序维护的分页结果。
  static final LinkedHashMap<int, List<ReaderTextPage>> _entries =
      LinkedHashMap<int, List<ReaderTextPage>>();

  /// 读取分页结果并把命中项移动到最近使用位置。
  static List<ReaderTextPage>? get(int signature) {
    /// 当前签名对应的缓存页面。
    final List<ReaderTextPage>? pages = _entries.remove(signature);
    if (pages != null) {
      _entries[signature] = pages;
    }
    return pages;
  }

  /// 保存不可变分页结果，并淘汰最久未使用的章节。
  static void put(int signature, List<ReaderTextPage> pages) {
    _entries.remove(signature);
    _entries[signature] = List<ReaderTextPage>.unmodifiable(pages);
    while (_entries.length > _maximumEntryCount) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// 以小批次继续计算完整分页，避免超长章节在首屏后再次长时间阻塞 UI。
final class _ReaderIncrementalPageLayoutJob {
  /// 创建一个只服务于当前章节和当前排版签名的后台分页任务。
  _ReaderIncrementalPageLayoutJob({
    required this.title,
    required this.text,
    required this.bodyStyle,
    required this.titleStyle,
    required this.maxWidth,
    required this.maxHeight,
    required this.titleTopSpacing,
    required this.titleBottomSpacing,
    required this.paragraphSpacing,
    required this.paragraphIndent,
    required this.textFullJustify,
    required this.textDirection,
    required this.textScaler,
  }) : paragraphs = text.split('\n');

  /// 当前章节第一页标题文本，可能因用户配置隐藏而为空。
  final String title;

  /// 当前章节处理后的完整正文。
  final String text;

  /// 正文行测量使用的样式。
  final TextStyle bodyStyle;

  /// 标题行测量使用的样式。
  final TextStyle titleStyle;

  /// 当前分页正文区域宽度。
  final double maxWidth;

  /// 当前分页正文区域高度。
  final double maxHeight;

  /// 标题顶部留白。
  final double titleTopSpacing;

  /// 标题底部留白。
  final double titleBottomSpacing;

  /// 段落底部留白。
  final double paragraphSpacing;

  /// 首行显示缩进字数。
  final int paragraphIndent;

  /// 正文是否启用两端对齐。
  final bool textFullJustify;

  /// 当前文本方向。
  final TextDirection textDirection;

  /// 当前系统文本缩放策略。
  final TextScaler textScaler;

  /// 已拆分的正文段落，保留换行字符对应的字符偏移计算。
  final List<String> paragraphs;

  /// 已完成的分页结果。
  final List<ReaderTextPage> pages = <ReaderTextPage>[];

  /// 当前页面已经装入的行。
  List<ReaderPageLine> currentLines = <ReaderPageLine>[];

  /// 当前页面已使用高度。
  double usedHeight = 0;

  /// 当前页面首个正文字符偏移。
  int? pageStartOffset;

  /// 当前页面正文结束字符偏移。
  int pageEndOffset = 0;

  /// 后台任务是否已经完成标题测量。
  bool titleLaidOut = false;

  /// 下一个待测量段落索引。
  int paragraphIndex = 0;

  /// 下一个待测量段落在完整正文中的起始偏移。
  int paragraphStartOffset = 0;

  /// 分批完成完整分页，每处理少量段落或页面后主动让出事件循环。
  Future<List<ReaderTextPage>> run() async {
    if ((title.isEmpty && text.isEmpty) || maxWidth <= 0 || maxHeight <= 0) {
      return const <ReaderTextPage>[];
    }
    if (!titleLaidOut) {
      _layoutTitle();
      titleLaidOut = true;
      await Future<void>.delayed(Duration.zero);
    }
    while (paragraphIndex < paragraphs.length) {
      /// 当前批次开始时已经完成的页数，用于控制单批工作量。
      final int pageCountAtSliceStart = pages.length;
      /// 当前批次已经处理的段落数。
      int paragraphCountInSlice = 0;
      while (paragraphIndex < paragraphs.length) {
        _layoutParagraph(paragraphIndex);
        paragraphIndex += 1;
        paragraphCountInSlice += 1;
        if (paragraphCountInSlice >= 6 ||
            pages.length - pageCountAtSliceStart >= 2) {
          break;
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    _finishPage();
    return List<ReaderTextPage>.unmodifiable(pages);
  }

  /// 测量并装入章节标题行。
  void _layoutTitle() {
    if (title.isEmpty) {
      return;
    }
    if (titleTopSpacing > 0 && titleTopSpacing < maxHeight) {
      currentLines.add(
        ReaderPageLine(
          kind: ReaderPageLineKind.spacer,
          text: '',
          height: titleTopSpacing,
          startOffset: 0,
          endOffset: 0,
        ),
      );
      usedHeight += titleTopSpacing;
    }
    /// 标题按独立样式测量得到的行列表。
    final List<ReaderPageLine> titleLines = ReaderPageLayoutEngine._measureLines(
      text: title,
      style: titleStyle,
      kind: ReaderPageLineKind.title,
      sourceStartOffset: 0,
      syntheticPrefixLength: 0,
      includeTrailingOffset: false,
      maxWidth: maxWidth,
      textDirection: textDirection,
      textScaler: textScaler,
      textFullJustify: false,
    );
    for (final ReaderPageLine line in titleLines) {
      _appendLine(line);
    }
    _appendSpacing(titleBottomSpacing);
  }

  /// 测量并装入指定段落，同时更新完整正文偏移。
  void _layoutParagraph(int index) {
    /// 当前原始段落。
    final String paragraph = paragraphs[index];
    /// 当前段落后是否存在换行字符。
    final bool hasTrailingNewline = index < paragraphs.length - 1;
    /// 当前段落被拆成的测量片段，避免单个无换行长段落阻塞后台续算。
    final List<String> chunks = ReaderPageLayoutEngine._paragraphChunks(paragraph);
    /// 当前片段在本段落内的原始字符起点。
    int chunkStartOffset = 0;
    for (int chunkIndex = 0; chunkIndex < chunks.length; chunkIndex += 1) {
      /// 当前待测量片段。
      final String chunk = chunks[chunkIndex];
      /// 当前片段是否是段落第一段，用于决定是否显示首行缩进。
      final bool isFirstChunk = chunkIndex == 0;
      /// 当前片段是否是段落最后一段，用于决定是否计入真实换行。
      final bool isLastChunk = chunkIndex == chunks.length - 1;
      /// 只用于显示、不参与正文锚点的缩进。
      final String indent = isFirstChunk
          ? List<String>.filled(paragraphIndent, '　').join()
          : '';
      /// 带显示缩进的段落片段文本。
      final String displayParagraph = '$indent$chunk';
      /// 当前片段按真实排版测量得到的行。
      final List<ReaderPageLine> paragraphLines = ReaderPageLayoutEngine._measureLines(
        text: displayParagraph,
        style: bodyStyle,
        kind: ReaderPageLineKind.body,
        sourceStartOffset: paragraphStartOffset + chunkStartOffset,
        syntheticPrefixLength: indent.length,
        includeTrailingOffset: hasTrailingNewline && isLastChunk,
        maxWidth: maxWidth,
        textDirection: textDirection,
        textScaler: textScaler,
        textFullJustify: textFullJustify,
      );
      for (final ReaderPageLine line in paragraphLines) {
        _appendLine(line);
      }
      chunkStartOffset += chunk.length;
    }
    _appendSpacing(paragraphSpacing);
    paragraphStartOffset += paragraph.length + (hasTrailingNewline ? 1 : 0);
  }

  /// 将一行加入当前页，超出高度时先结束旧页。
  void _appendLine(ReaderPageLine line) {
    if (currentLines.isNotEmpty && usedHeight + line.height > maxHeight) {
      _finishPage();
    }
    currentLines.add(line);
    usedHeight += line.height;
    if (line.kind == ReaderPageLineKind.body && line.endOffset > line.startOffset) {
      pageStartOffset ??= line.startOffset;
      pageEndOffset = line.endOffset;
    }
  }

  /// 在当前页追加垂直间距，超出页面时不把空白带到下一页顶部。
  void _appendSpacing(double height) {
    if (height <= 0 || currentLines.isEmpty) {
      return;
    }
    if (usedHeight + height > maxHeight) {
      _finishPage();
      return;
    }
    _appendLine(
      ReaderPageLine(
        kind: ReaderPageLineKind.spacer,
        text: '',
        height: height,
        startOffset: pageEndOffset,
        endOffset: pageEndOffset,
      ),
    );
  }

  /// 完成当前页面并重置逐页累积状态。
  void _finishPage() {
    if (currentLines.isEmpty) {
      return;
    }
    pages.add(
      ReaderTextPage(
        startOffset: pageStartOffset ?? pageEndOffset,
        endOffset: pageEndOffset,
        lines: currentLines,
      ),
    );
    currentLines = <ReaderPageLine>[];
    usedHeight = 0;
    pageStartOffset = null;
  }
}

/// 使用 PageView 渲染动态分页正文并处理点击区域和章节边界。
final class ReaderPagedContent extends StatefulWidget {
  /// 创建逐页阅读内容。
  const ReaderPagedContent({required this.state, required this.onIntent, super.key});

  /// 当前阅读器业务状态。
  final ReaderUiState state;

  /// 阅读器 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 创建分页组件瞬时状态。
  @override
  State<ReaderPagedContent> createState() => _ReaderPagedContentState();
}

/// 持有仅与当前布局有关的 PageController 和恢复请求编号。
final class _ReaderPagedContentState extends State<ReaderPagedContent>
    with SingleTickerProviderStateMixin {
  /// 分页页眉固定高度，测量和渲染必须共同使用。
  static const double _headerHeight = 16;

  /// 页眉与正文之间的固定间距。
  static const double _headerSpacing = 12;

  /// 分页页脚固定高度，测量和渲染必须共同使用。
  static const double _footerHeight = 16;

  /// 首次进入长章节时优先测量的页数，保证首屏和短时间翻页先可用。
  static const int _initialLayoutPageCount = 8;

  /// 当前章节页面控制器，不写入业务状态。
  final PageController _pageController = PageController();

  /// 分页阅读按键监听焦点，用于接收桌面键盘和 Android 音量键翻页。
  final FocusNode _keyboardFocusNode = FocusNode(debugLabel: 'ReaderPagedKeyFocus');

  /// 覆盖翻页动画控制器。
  late final AnimationController _coverController;

  /// 最近已经按字符锚点处理的恢复请求编号。
  int _lastRestoreRequestId = -1;

  /// 当前布局计算得到的页面列表。
  List<ReaderTextPage> _pages = const <ReaderTextPage>[];

  /// 最近一次分页输入签名，避免字符锚点状态更新时重复测量整章正文。
  int? _layoutSignature;

  /// 当前分页组件内部显示的页面索引。
  int _currentPageIndex = 0;

  /// 当前分页结果是否已经包含完整章节。
  bool _isLayoutComplete = false;

  /// 用于丢弃旧章节或旧样式触发的后台分页结果。
  int _layoutGeneration = 0;

  /// 覆盖翻页动画开始时的底层页面索引。
  int? _coverFromIndex;

  /// 覆盖翻页动画目标页面索引。
  int? _coverToIndex;

  /// 覆盖翻页方向，正数表示当前页左移露出下一页，负数表示上一页从左侧覆盖。
  int _coverDirection = 1;

  /// 当前横向拖动累计距离，用于判断覆盖翻页方向和提交阈值。
  double _horizontalDragDistance = 0;

  /// 当前横向拖动所在阅读区域宽度，用于把距离换算为动画进度。
  double _horizontalDragWidth = 1;

  /// 本次横向手势是否成功取得覆盖翻页控制权。
  bool _horizontalDragEnabled = false;

  /// 初始化覆盖翻页动画控制器。
  @override
  void initState() {
    super.initState();
    _coverController = AnimationController(
      vsync: this,
      duration: DurationToken.medium,
    );
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (mounted) {
        _keyboardFocusNode.requestFocus();
      }
    });
  }

  /// 释放页面控制器。
  @override
  void dispose() {
    _coverController.dispose();
    _keyboardFocusNode.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// 构建随屏幕尺寸和阅读设置重新计算的分页正文。
  @override
  Widget build(BuildContext context) {
    /// 当前已经处理完成的章节正文。
    final ReaderChapterContent? content = widget.state.content;
    if (content == null) {
      return const SizedBox.shrink();
    }
    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleReaderKey,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
        /// 当前正文使用的完整文字样式。
        final TextStyle textStyle = TextStyle(
          color: Color(widget.state.config.textColorValue),
          fontSize: widget.state.config.fontSize,
          fontWeight: _fontWeight(widget.state.config.fontWeightValue),
          fontStyle: widget.state.config.textItalic ? FontStyle.italic : FontStyle.normal,
          letterSpacing: widget.state.config.letterSpacing,
          decoration: widget.state.config.textUnderline
              ? TextDecoration.underline
              : TextDecoration.none,
          shadows: _textShadows(widget.state),
          height: widget.state.config.lineHeight,
        );
        /// 第一页章节标题使用的独立文字样式。
        final TextStyle titleStyle = TextStyle(
          color: Color(widget.state.config.textColorValue),
          fontSize: widget.state.config.fontSize +
              widget.state.config.titleFontSizeOffset,
          fontWeight: _fontWeight(widget.state.config.titleFontWeightValue),
          fontStyle: widget.state.config.textItalic ? FontStyle.italic : FontStyle.normal,
          letterSpacing: widget.state.config.letterSpacing,
          shadows: _textShadows(widget.state),
          height: 1.35,
        );
        /// 宽屏下限制正文行长后的实际排版宽度。
        final double contentWidth = (constraints.maxWidth -
                widget.state.config.horizontalPadding * 2)
            .clamp(1, LayoutToken.readerMaxWidth)
            .toDouble();
        /// 页眉页脚开启时占据的精确固定高度。
        final double chromeHeight = widget.state.config.showHeaderFooter
            ? _headerHeight + _headerSpacing + _footerHeight
            : 0;
        /// 扣除真实页眉、页脚和上下边距后的正文排版高度。
        final double contentHeight =
            (constraints.maxHeight - chromeHeight - widget.state.config.verticalPadding * 2)
                .clamp(1, double.infinity)
                .toDouble();
        /// 当前系统文字缩放策略。
        final TextScaler textScaler = MediaQuery.textScalerOf(context);
        /// 会影响分页边界的全部稳定输入签名。
        final int layoutSignature = Object.hashAll(<Object?>[
          content.chapterUrl,
          content.title,
          content.text,
          widget.state.config.fontSize,
          widget.state.config.fontWeightValue,
          widget.state.config.textItalic,
          widget.state.config.letterSpacing,
          widget.state.config.textShadow,
          widget.state.config.textUnderline,
          widget.state.config.lineHeight,
          widget.state.config.paragraphSpacing,
          widget.state.config.verticalPadding,
          widget.state.config.showHeaderFooter,
          widget.state.config.titleMode,
          widget.state.config.titleFontSizeOffset,
          widget.state.config.titleFontWeightValue,
          widget.state.config.titleTopSpacing,
          widget.state.config.titleBottomSpacing,
          widget.state.config.paragraphIndent,
          widget.state.config.textFullJustify,
          contentWidth,
          contentHeight,
          textScaler.scale(10),
        ]);
        if (_layoutSignature != layoutSignature) {
          _layoutSignature = layoutSignature;
          _layoutGeneration += 1;
          /// 当前签名已经缓存的完整分页结果。
          final List<ReaderTextPage>? cachedPages =
              ReaderPageLayoutCache.get(layoutSignature);
          if (cachedPages != null) {
            _pages = cachedPages;
            _isLayoutComplete = true;
          } else {
            _isLayoutComplete = false;
            _pages = ReaderPageLayoutEngine.paginate(
                title: widget.state.config.titleMode == ReaderTitleMode.hidden
                    ? ''
                    : content.title,
                text: content.text,
                bodyStyle: textStyle,
                titleStyle: titleStyle,
                maxWidth: contentWidth,
                maxHeight: contentHeight,
                titleTopSpacing: widget.state.config.titleTopSpacing,
                titleBottomSpacing: widget.state.config.titleBottomSpacing,
                paragraphSpacing: widget.state.config.paragraphSpacing,
                paragraphIndent: widget.state.config.paragraphIndent,
                textFullJustify: widget.state.config.textFullJustify,
                textDirection: Directionality.of(context),
                textScaler: textScaler,
                maximumPageCount: _initialLayoutPageCount,
                minimumEndOffset: widget.state.anchor?.characterOffset ?? 0,
              );
            _scheduleCompletePagination(
              signature: layoutSignature,
              generation: _layoutGeneration,
              content: content,
              bodyStyle: textStyle,
              titleStyle: titleStyle,
              contentWidth: contentWidth,
              contentHeight: contentHeight,
              textDirection: Directionality.of(context),
              textScaler: textScaler,
            );
          }
          if (_pages.isNotEmpty && _currentPageIndex >= _pages.length) {
            _currentPageIndex = _pages.length - 1;
          }
        }
        _restorePage(widget.state);
        if (_usesCoverPaging) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (TapUpDetails details) {
              _handleTap(details.localPosition.dx, constraints.maxWidth);
            },
            onLongPress: _handleLongPress,
            onHorizontalDragStart: (DragStartDetails details) {
              _handleHorizontalDragStart(constraints.maxWidth);
            },
            onHorizontalDragUpdate: _handleHorizontalDragUpdate,
            onHorizontalDragEnd: _handleHorizontalDragEnd,
            child: _buildCoverPager(content, textStyle, titleStyle, contentWidth),
          );
        }
        return NotificationListener<OverscrollNotification>(
          onNotification: (OverscrollNotification notification) {
            if (notification.metrics.extentBefore <= 1 &&
                notification.overscroll < -16 &&
                widget.state.canGoPrevious) {
              widget.onIntent(const OpenPreviousChapterIntent());
            }
            return false;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (TapUpDetails details) {
              _handleTap(details.localPosition.dx, constraints.maxWidth);
            },
            onLongPress: _handleLongPress,
            child: PageView.builder(
              controller: _pageController,
              scrollDirection:
                  widget.state.config.readingMode == ReaderReadingMode.verticalPaging
                      ? Axis.vertical
                      : Axis.horizontal,
              itemCount: _pages.length +
                  (_isLayoutComplete && widget.state.canGoNext ? 1 : 0) +
                  (!_isLayoutComplete ? 1 : 0),
              onPageChanged: _handlePageChanged,
              itemBuilder: (BuildContext context, int index) {
                if (index >= _pages.length) {
                  return const Center(child: CircularProgressIndicator());
                }
                /// 当前需要渲染的正文页。
                final ReaderTextPage page = _pages[index];
                return _buildPage(
                  content,
                  textStyle,
                  titleStyle,
                  contentWidth,
                  index,
                  page,
                );
              },
            ),
          ),
        );
      },
      ),
    );
  }

  /// 处理分页模式下的音量键翻页，优先翻当前页而不是直接切章。
  void _handleReaderKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        widget.state.activeSheet != null ||
        !widget.state.config.volumeKeyTurnPage) {
      return;
    }
    /// 当前逻辑按键。
    final LogicalKeyboardKey logicalKey = event.logicalKey;
    if (logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      _performTapAction(ReaderTapAction.previousPage);
      return;
    }
    if (logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      _performTapAction(ReaderTapAction.nextPage);
    }
  }

  /// 当前是否使用覆盖翻页渲染路径。
  bool get _usesCoverPaging {
    return widget.state.config.readingMode == ReaderReadingMode.horizontalPaging &&
        widget.state.config.pageTurnStyle == ReaderPageTurnStyle.cover;
  }

  /// 在首批页面绘制后继续测量完整章节，并只回填仍匹配当前签名的结果。
  void _scheduleCompletePagination({
    required int signature,
    required int generation,
    required ReaderChapterContent content,
    required TextStyle bodyStyle,
    required TextStyle titleStyle,
    required double contentWidth,
    required double contentHeight,
    required TextDirection textDirection,
    required TextScaler textScaler,
  }) {
    /// 当前配置下第一页正文标题；隐藏标题只影响正文页，不影响页眉显示。
    final String layoutTitle =
        widget.state.config.titleMode == ReaderTitleMode.hidden ? '' : content.title;
    /// 当前配置下标题顶部留白。
    final double titleTopSpacing = widget.state.config.titleTopSpacing;
    /// 当前配置下标题底部留白。
    final double titleBottomSpacing = widget.state.config.titleBottomSpacing;
    /// 当前配置下段落间距。
    final double paragraphSpacing = widget.state.config.paragraphSpacing;
    /// 当前配置下首行缩进字数。
    final int paragraphIndent = widget.state.config.paragraphIndent;
    /// 当前配置下两端对齐开关。
    final bool textFullJustify = widget.state.config.textFullJustify;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      Future<void>.delayed(Duration.zero).then((_) async {
        if (!mounted ||
            _layoutSignature != signature ||
            _layoutGeneration != generation) {
          return;
        }
        /// 后台续算任务；TextPainter 需要 UI isolate，因此按段落批次主动让出事件循环。
        final _ReaderIncrementalPageLayoutJob layoutJob =
            _ReaderIncrementalPageLayoutJob(
          title: layoutTitle,
          text: content.text,
          bodyStyle: bodyStyle,
          titleStyle: titleStyle,
          maxWidth: contentWidth,
          maxHeight: contentHeight,
          titleTopSpacing: titleTopSpacing,
          titleBottomSpacing: titleBottomSpacing,
          paragraphSpacing: paragraphSpacing,
          paragraphIndent: paragraphIndent,
          textFullJustify: textFullJustify,
          textDirection: textDirection,
          textScaler: textScaler,
        );
        /// 后台续算得到的完整分页结果。
        final List<ReaderTextPage> completePages = await layoutJob.run();
        ReaderPageLayoutCache.put(signature, completePages);
        if (!mounted ||
            _layoutSignature != signature ||
            _layoutGeneration != generation) {
          return;
        }
        /// 当前可见页面的稳定字符位置，用于完整分页回填后保持阅读位置。
        final int visibleOffset = _pages.isEmpty
            ? (widget.state.anchor?.characterOffset ?? 0)
            : _pages[_currentPageIndex.clamp(0, _pages.length - 1).toInt()]
                .startOffset;
        setState(() {
          _pages = completePages;
          _isLayoutComplete = true;
          _currentPageIndex = _pageIndexForOffset(visibleOffset);
          _coverFromIndex = null;
          _coverToIndex = null;
        });
        WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
          if (!mounted || !_pageController.hasClients) {
            return;
          }
          _pageController.jumpToPage(_currentPageIndex);
        });
      });
    });
  }

  /// 构建覆盖翻页内容栈。
  Widget _buildCoverPager(
    ReaderChapterContent content,
    TextStyle textStyle,
    TextStyle titleStyle,
    double contentWidth,
  ) {
    if (_pages.isEmpty) {
      return const SizedBox.shrink();
    }
    /// 底层页面索引。
    final int baseIndex = (_coverFromIndex ?? _currentPageIndex)
        .clamp(0, _pages.length - 1)
        .toInt();
    /// 覆盖目标页面索引。
    final int? targetIndex = _coverToIndex;
    /// 底层页面。
    final Widget basePage = _buildPage(
      content,
      textStyle,
      titleStyle,
      contentWidth,
      baseIndex,
      _pages[baseIndex],
    );
    if (targetIndex == null || targetIndex < 0 || targetIndex >= _pages.length) {
      return basePage;
    }
    return AnimatedBuilder(
      animation: _coverController,
      builder: (BuildContext context, Widget? child) {
        /// 页面宽度，用于把动画进度换算为覆盖页偏移。
        final double width = MediaQuery.sizeOf(context).width;
        /// 上一页从屏幕左侧覆盖回来时的剩余位移。
        final double previousOffset = -(1 - _coverController.value) * width;
        /// 当前动画目标页。
        final Widget targetPage = _buildPage(
          content,
          textStyle,
          titleStyle,
          contentWidth,
          targetIndex,
          _pages[targetIndex],
        );
        if (_coverDirection > 0) {
          /// 翻下一页时下一页固定在底层，当前纸张向左移走，保持 Android CoverPageDelegate 语义。
          final double currentOffset = -_coverController.value * width;
          return Stack(
            children: <Widget>[
              Positioned.fill(child: targetPage),
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(currentOffset, 0),
                  child: _buildCoverShadow(basePage),
                ),
              ),
            ],
          );
        }
        /// 翻上一页时当前页固定在底层，上一页从左侧覆盖回来。
        return Stack(
          children: <Widget>[
            Positioned.fill(child: basePage),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(previousOffset, 0),
                child: _buildCoverShadow(targetPage),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 为移动纸张添加覆盖边缘阴影，强化页面压在另一页上方的层次。
  Widget _buildCoverShadow(Widget page) {
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(4, 0),
          ),
        ],
      ),
      child: page,
    );
  }

  /// 构建分页模式下的一页正文。
  Widget _buildPage(
    ReaderChapterContent content,
    TextStyle textStyle,
    TextStyle titleStyle,
    double contentWidth,
    int index,
    ReaderTextPage page,
  ) {
    return ColoredBox(
      color: Color(widget.state.config.backgroundColorValue),
      child: Center(
        child: SizedBox(
          width: contentWidth,
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: widget.state.config.verticalPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (widget.state.config.showHeaderFooter)
                  SizedBox(
                    height: _headerHeight,
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            content.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Color(widget.state.config.textColorValue)
                                  .withValues(alpha: 0.68),
                              fontSize: 12,
                            ),
                          ),
                        ),
                        ReaderSystemInfoText(
                          config: widget.state.config,
                          batteryLevel: widget.state.batteryLevel,
                          textColor: Color(widget.state.config.textColorValue)
                              .withValues(alpha: 0.58),
                          fontSize: 11,
                        ),
                      ],
                    ),
                  ),
                if (widget.state.config.showHeaderFooter)
                  const SizedBox(height: _headerSpacing),
                Expanded(
                  child: _buildPageLines(page, textStyle, titleStyle),
                ),
                if (widget.state.config.showHeaderFooter)
                  SizedBox(
                    height: _footerHeight,
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            widget.state.book?.name ?? '阅读',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Color(widget.state.config.textColorValue)
                                  .withValues(alpha: 0.5),
                              fontSize: 11,
                            ),
                          ),
                        ),
                        Text(
                          _pageFooterText(index, page),
                          maxLines: 1,
                          style: TextStyle(
                            color: Color(widget.state.config.textColorValue)
                                .withValues(alpha: 0.55),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 按分页器测量结果逐行绘制标题、正文和段落间距，避免渲染阶段再次换行。
  Widget _buildPageLines(
    ReaderTextPage page,
    TextStyle bodyStyle,
    TextStyle titleStyle,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: page.lines.map((ReaderPageLine line) {
        if (line.kind == ReaderPageLineKind.spacer) {
          return SizedBox(height: line.height);
        }
        /// 当前排版行对应的标题或正文样式。
        final TextStyle style = line.kind == ReaderPageLineKind.title
            ? titleStyle
            : bodyStyle.copyWith(
                letterSpacing: (bodyStyle.letterSpacing ?? 0) +
                    line.extraLetterSpacing,
                wordSpacing: (bodyStyle.wordSpacing ?? 0) +
                    line.extraWordSpacing,
              );
        return SizedBox(
          height: line.height,
          child: Text(
            line.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: style,
            textAlign: line.kind == ReaderPageLineKind.title &&
                    widget.state.config.titleMode == ReaderTitleMode.center
                ? TextAlign.center
                : TextAlign.start,
          ),
        );
      }).toList(growable: false),
    );
  }

  /// 按稳定字符锚点把当前布局恢复到对应页面。
  void _restorePage(ReaderUiState state) {
    if (_pages.isEmpty || state.restoreRequestId == _lastRestoreRequestId) {
      return;
    }
    _lastRestoreRequestId = state.restoreRequestId;
    /// 当前稳定字符位置。
    final int characterOffset = state.anchor?.characterOffset ?? 0;
    _currentPageIndex = _pageIndexForOffset(characterOffset);
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (!mounted) {
        return;
      }
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentPageIndex);
      }
    });
  }

  /// 查找稳定字符位置所在页；预览分页未覆盖该位置时停在已测量的最后一页。
  int _pageIndexForOffset(int characterOffset) {
    if (_pages.isEmpty || characterOffset <= 0) {
      return 0;
    }
    /// 包含稳定字符位置的页面索引。
    final int pageIndex = _pages.indexWhere((ReaderTextPage page) {
      return characterOffset >= page.startOffset &&
          characterOffset < page.endOffset;
    });
    if (pageIndex >= 0) {
      return pageIndex;
    }
    /// 如果后台完整分页尚未完成，锚点可能落在预览末尾之后，先保持最后一页。
    return _pages.length - 1;
  }

  /// 保存翻页后的字符位置，并在越过末页时自动进入下一章。
  void _handlePageChanged(int index) {
    if (index >= _pages.length) {
      if (_isLayoutComplete) {
        widget.onIntent(const OpenNextChapterIntent());
      }
      return;
    }
    _currentPageIndex = index;
    widget.onIntent(UpdateReaderScrollIntent(_pages[index].startOffset));
  }

  /// 按用户配置把正文点击区域映射为阅读动作。
  void _handleTap(double x, double width) {
    /// 当前左侧点击区域宽度。
    final double leftWidth = width * widget.state.config.leftTapWidthRatio;
    /// 当前右侧点击区域起点。
    final double rightStart = width * (1 - widget.state.config.rightTapWidthRatio);
    if (x < leftWidth) {
      _performTapAction(widget.state.config.leftTapAction);
      return;
    }
    if (x > rightStart) {
      _performTapAction(widget.state.config.rightTapAction);
      return;
    }
    _performTapAction(widget.state.config.centerTapAction);
  }

  /// 执行用户配置的正文长按动作。
  void _handleLongPress() {
    _performTapAction(widget.state.config.longPressAction);
  }

  /// 执行正文点击、长按和按键共享的阅读动作。
  void _performTapAction(ReaderTapAction action) {
    switch (action) {
      case ReaderTapAction.none:
        return;
      case ReaderTapAction.previousPage:
        _openPreviousPageOrChapter();
        return;
      case ReaderTapAction.nextPage:
        _openNextPageOrChapter();
        return;
      case ReaderTapAction.toggleMenu:
        widget.onIntent(const ToggleReaderMenuIntent());
        return;
      case ReaderTapAction.addBookmark:
        widget.onIntent(const AddReaderBookmarkIntent());
        return;
    }
  }

  /// 优先翻到当前章节上一页，到达边界后进入上一章。
  void _openPreviousPageOrChapter() {
    if (_usesCoverPaging && _currentPageIndex > 0) {
      _turnToPage(_currentPageIndex - 1);
      return;
    }
    if (_pageController.hasClients && (_pageController.page ?? 0) > 0) {
      _turnToPage((_pageController.page ?? 0).round() - 1);
      return;
    }
    if (_isLayoutComplete && widget.state.canGoPrevious) {
      widget.onIntent(const OpenPreviousChapterIntent());
    }
  }

  /// 优先翻到当前章节下一页，到达边界后进入下一章。
  void _openNextPageOrChapter() {
    if (_usesCoverPaging && _currentPageIndex < _pages.length - 1) {
      _turnToPage(_currentPageIndex + 1);
      return;
    }
    if (_pageController.hasClients &&
        (_pageController.page ?? 0) < _pages.length - 1) {
      _turnToPage((_pageController.page ?? 0).round() + 1);
      return;
    }
    if (_isLayoutComplete && widget.state.canGoNext) {
      widget.onIntent(const OpenNextChapterIntent());
    }
  }

  /// 开始横向覆盖拖动，并记录本次手势使用的稳定页面宽度。
  void _handleHorizontalDragStart(double width) {
    _horizontalDragEnabled = !_coverController.isAnimating;
    if (!_horizontalDragEnabled) {
      return;
    }
    _horizontalDragDistance = 0;
    _horizontalDragWidth = width <= 0 ? 1 : width;
  }

  /// 根据手指水平位移实时拖入上一页或下一页覆盖层。
  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_horizontalDragEnabled || _coverController.isAnimating || _pages.isEmpty) {
      return;
    }
    _horizontalDragDistance += details.delta.dx;
    if (_horizontalDragDistance == 0) {
      return;
    }
    /// 手势目标方向；左滑进入下一页，右滑进入上一页。
    final int direction = _horizontalDragDistance < 0 ? 1 : -1;
    /// 当前章节内与手势方向对应的目标页索引。
    final int targetIndex = _currentPageIndex + direction;
    if (targetIndex < 0 || targetIndex >= _pages.length) {
      if (_coverToIndex != null) {
        setState(() {
          _coverFromIndex = null;
          _coverToIndex = null;
        });
        _coverController.value = 0;
      }
      return;
    }
    if (_coverToIndex != targetIndex) {
      setState(() {
        _coverFromIndex = _currentPageIndex;
        _coverToIndex = targetIndex;
        _coverDirection = direction;
      });
      _coverController.value = 0;
    }
    /// 当前拖动距离对应的受控覆盖进度。
    final double progress = (_horizontalDragDistance.abs() / _horizontalDragWidth)
        .clamp(0, 1)
        .toDouble();
    _coverController.value = progress;
  }

  /// 按距离或速度决定完成翻页、回弹，或在章节边界进入相邻章节。
  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (!_horizontalDragEnabled || _pages.isEmpty) {
      return;
    }
    _horizontalDragEnabled = false;
    /// 手势目标方向；左滑进入下一页，右滑进入上一页。
    final int direction = _horizontalDragDistance < 0 ? 1 : -1;
    /// 水平结束速度，正数向右、负数向左。
    final double velocity = details.primaryVelocity ?? 0;
    /// 拖动是否达到提交覆盖翻页的距离或速度阈值。
    final bool shouldCommit = _horizontalDragDistance.abs() >= _horizontalDragWidth * 0.22 ||
        (direction > 0 ? velocity < -500 : velocity > 500);
    /// 当前章节内已经准备好的目标页。
    final int? targetIndex = _coverToIndex;
    if (targetIndex != null) {
      if (shouldCommit) {
        _finishCoverAnimation(targetIndex);
      } else {
        _cancelCoverAnimation();
      }
      _horizontalDragDistance = 0;
      return;
    }
    if (shouldCommit && direction > 0 && _isLayoutComplete && widget.state.canGoNext) {
      widget.onIntent(const OpenNextChapterIntent());
    } else if (shouldCommit &&
        direction < 0 &&
        _isLayoutComplete &&
        widget.state.canGoPrevious) {
      widget.onIntent(const OpenPreviousChapterIntent());
    }
    _horizontalDragDistance = 0;
  }

  /// 将跨平台保存的字重数值映射为 Flutter 字体权重。
  FontWeight _fontWeight(int value) {
    return switch (value) {
      300 => FontWeight.w300,
      500 => FontWeight.w500,
      600 => FontWeight.w600,
      700 => FontWeight.w700,
      _ => FontWeight.w400,
    };
  }

  /// 按用户配置切换到目标页面。
  void _turnToPage(int index) {
    if (_usesCoverPaging) {
      _animateCoverToPage(index);
      return;
    }
    if (!_pageController.hasClients) {
      return;
    }
    if (widget.state.config.pageTurnStyle == ReaderPageTurnStyle.none) {
      _pageController.jumpToPage(index);
      return;
    }
    _pageController.animateToPage(
      index,
      duration: DurationToken.medium,
      curve: AnimationToken.standard,
    );
  }

  /// 使用覆盖翻页动画切换到目标页面。
  void _animateCoverToPage(int index) {
    if (_pages.isEmpty || _coverController.isAnimating) {
      return;
    }
    /// 目标页索引。
    final int targetIndex = index.clamp(0, _pages.length - 1).toInt();
    if (targetIndex == _currentPageIndex) {
      return;
    }
    setState(() {
      _coverFromIndex = _currentPageIndex;
      _coverToIndex = targetIndex;
      _coverDirection = targetIndex > _currentPageIndex ? 1 : -1;
    });
    _coverController.reset();
    _finishCoverAnimation(targetIndex);
  }

  /// 从当前动画进度完成覆盖翻页并保存目标页稳定字符锚点。
  void _finishCoverAnimation(int targetIndex) {
    /// 当前覆盖翻页动画任务。
    final Future<void> animation = _coverController.forward();
    animation.whenComplete(() {
      if (!mounted) {
        return;
      }
      setState(() {
        _currentPageIndex = targetIndex;
        _coverFromIndex = null;
        _coverToIndex = null;
      });
      widget.onIntent(UpdateReaderScrollIntent(_pages[targetIndex].startOffset));
    });
  }

  /// 将未达到阈值的覆盖页退回屏幕外，并清理本地手势状态。
  void _cancelCoverAnimation() {
    /// 当前覆盖页回弹任务。
    final Future<void> animation = _coverController.reverse();
    animation.whenComplete(() {
      if (!mounted) {
        return;
      }
      setState(() {
        _coverFromIndex = null;
        _coverToIndex = null;
      });
    });
  }

  /// 根据阅读配置生成轻量正文阴影。
  List<Shadow>? _textShadows(ReaderUiState state) {
    if (!state.config.textShadow) {
      return null;
    }
    return <Shadow>[
      Shadow(
        color: Color(state.config.textColorValue).withValues(alpha: 0.28),
        blurRadius: 1.5,
        offset: const Offset(0.6, 0.8),
      ),
    ];
  }

  /// 构建页脚显示文本。
  String _pageFooterText(int index, ReaderTextPage page) {
    /// 当前完整正文长度。
    final int textLength = widget.state.content?.text.length ?? 0;
    /// 当前页结束位置对应的章节百分比。
    final int percent = textLength <= 0
        ? 0
        : ((page.endOffset / textLength).clamp(0, 1) * 100).round();
    /// 完整分页未完成时总页数还会增长，使用省略号避免误导。
    final String totalText = _isLayoutComplete ? '${_pages.length}' : '…';
    return '${index + 1} / $totalText · $percent%';
  }
}

/// 显示阅读页眉页脚中的时间和电量，并每分钟自动刷新时间。
final class ReaderSystemInfoText extends StatefulWidget {
  /// 创建系统信息文本组件。
  const ReaderSystemInfoText({
    required this.config,
    required this.batteryLevel,
    required this.textColor,
    required this.fontSize,
    super.key,
  });

  /// 当前阅读显示配置，决定是否显示时间和电量。
  final ReaderDisplayConfig config;

  /// 平台返回的电量百分比；为空时隐藏电量。
  final int? batteryLevel;

  /// 文本颜色。
  final Color textColor;

  /// 文本字号。
  final double fontSize;

  /// 创建系统信息文本状态。
  @override
  State<ReaderSystemInfoText> createState() => _ReaderSystemInfoTextState();
}

/// 持有分钟级刷新定时器，避免每帧重建时间文本。
final class _ReaderSystemInfoTextState extends State<ReaderSystemInfoText> {
  /// 当前显示时间。
  DateTime _now = DateTime.now();

  /// 分钟刷新定时器。
  Timer? _timer;

  /// 初始化定时刷新。
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (Timer timer) {
      if (mounted) {
        setState(() {
          _now = DateTime.now();
        });
      }
    });
  }

  /// 释放定时器。
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 构建时间、电量组合文本。
  @override
  Widget build(BuildContext context) {
    /// 当前需要显示的片段。
    final List<String> parts = <String>[];
    if (widget.config.showClock) {
      parts.add(_formatTime(_now));
    }
    final int? batteryLevel = widget.batteryLevel;
    if (widget.config.showBattery && batteryLevel != null) {
      parts.add('$batteryLevel%');
    }
    if (parts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: widget.textColor,
        fontSize: widget.fontSize,
      ),
    );
  }

  /// 格式化为阅读器页眉使用的 24 小时时间。
  String _formatTime(DateTime time) {
    /// 两位小时。
    final String hour = time.hour.toString().padLeft(2, '0');
    /// 两位分钟。
    final String minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
