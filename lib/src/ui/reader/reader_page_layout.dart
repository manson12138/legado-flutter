import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/model/book_content_process.dart';
import '../../domain/model/reader_content.dart';
import '../../help/logging/app_logger.dart';
import '../theme/app_tokens.dart';
import 'reader_contract.dart';
import 'reader_content_image.dart';
import 'reader_selection_region.dart';
import 'reader_simulation_page_turn.dart';
import 'reader_tap_region.dart';

/// 标记分页行使用章节标题、正文或仅占据垂直空间。
enum ReaderPageLineKind {
  /// 第一页章节标题行。
  title,

  /// 参与阅读进度计算的正文行。
  body,

  /// 占据独立页面的正文图片资源。
  image,

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
    this.altText = '',
    this.referer = '',
  });

  /// 当前行的标题、正文或间距类型。
  final ReaderPageLineKind kind;

  /// 当前行实际绘制的文本；间距行固定为空字符串。
  final String text;

  /// 图片行加载失败时展示的替代文本；其他行固定为空字符串。
  final String altText;

  /// 图片请求可携带的正文页面 Referer；其他行固定为空字符串。
  final String referer;

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
      if (paragraph == '\uFFFC') {
        paragraphStartOffset += paragraph.length + (hasTrailingNewline ? 1 : 0);
        continue;
      }
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

  /// 在纯文本分页完成后按稳定字符位置插入独立图片页。
  static List<ReaderTextPage> insertImagePages({
    required List<ReaderTextPage> pages,
    required List<ReaderContentImage> images,
    required double pageHeight,
  }) {
    if (images.isEmpty || pageHeight <= 0) {
      return pages;
    }
    /// 可插入图片页的分页结果副本。
    final List<ReaderTextPage> output = List<ReaderTextPage>.of(pages);
    /// 按稳定字符位置排序的图片副本，保证同页多图不会因逐项插入而反序。
    final List<ReaderContentImage> orderedImages = List<ReaderContentImage>.of(images)
      ..sort(
        (ReaderContentImage left, ReaderContentImage right) =>
            left.characterOffset.compareTo(right.characterOffset),
      );
    for (final ReaderContentImage image in orderedImages) {
      /// 当前图片应插入到的页面索引。
      int insertionIndex = output.length;
      for (int pageIndex = 0; pageIndex < output.length; pageIndex += 1) {
        /// 当前候选页面。
        final ReaderTextPage page = output[pageIndex];
        /// 第一张起始位置更靠后的页面之前就是当前图片的稳定插入点。
        if (page.startOffset > image.characterOffset) {
          insertionIndex = pageIndex;
          break;
        }
      }
      output.insert(
        insertionIndex,
        ReaderTextPage(
          startOffset: image.characterOffset,
          endOffset: image.characterOffset + 1,
          lines: <ReaderPageLine>[
            ReaderPageLine(
              kind: ReaderPageLineKind.image,
              text: image.url,
              height: pageHeight,
              startOffset: image.characterOffset,
              endOffset: image.characterOffset + 1,
              altText: image.altText,
              referer: image.referer,
            ),
          ],
        ),
      );
    }
    return List<ReaderTextPage>.unmodifiable(output);
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
    if (paragraph == '\uFFFC') {
      paragraphStartOffset += paragraph.length + (hasTrailingNewline ? 1 : 0);
      return;
    }
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
  const ReaderPagedContent({
    required this.state,
    required this.onIntent,
    required this.logger,
    super.key,
  });

  /// 当前阅读器业务状态。
  final ReaderUiState state;

  /// 阅读器 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 【FLUTTER_READER_SIMULATION_LOG】仿真翻页临时诊断日志使用的统一应用日志器。
  final AppLogger logger;

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

  /// 页面上下边距：显示页眉页脚时页眉页脚只需贴近安全区留出固定小间距，
  /// 正文与安全区的距离改由页眉页脚下方的阅读边距承担；不显示页眉页脚时
  /// 仍按用户配置的阅读边距直接包裹正文。
  double get _edgeVerticalPadding => widget.state.config.showHeaderFooter
      ? SpacingToken.small
      : widget.state.config.verticalPadding;

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

  /// 每次翻页或分页结果替换时递增，用于清除上一页原生选区。
  int _selectionEpoch = 0;

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

  /// 本次横向手势超过松弛值后锁定的翻页方向，正数下一页、负数上一页。
  int _horizontalDragDirection = 0;

  /// 手指最后一次移动是否背离锁定翻页方向；仿真模式据此按 Android 语义回弹。
  bool _horizontalDragCancelRequested = false;

  /// 当前分页正文是否存在有效原生文字选区；激活时禁止横向翻页抢占手柄拖动。
  bool _selectionActive = false;

  /// 当前仿真页面尺寸，用于生成 Android 同类程序化起点、终点和动画时长。
  Size _simulationPageSize = Size.zero;

  /// 本次仿真手势或点击的起点；无用户起点时默认从页面下方启动。
  Offset _simulationGestureStart = const Offset(0, double.infinity);

  /// 当前仿真帧直接消费的真实二维触点。
  Offset _simulationTouch = Offset.zero;

  /// 本次仿真翻页锁定的右上或右下页角。
  Offset _simulationCorner = Offset.zero;

  /// 收尾动画开始时的二维触点。
  Offset _simulationMotionStartTouch = Offset.zero;

  /// 收尾动画完成时的二维触点。
  Offset _simulationMotionEndTouch = Offset.zero;

  /// 收尾二维插值对应的控制器起始值。
  double _simulationMotionStartValue = 0;

  /// 收尾二维插值对应的控制器结束值。
  double _simulationMotionEndValue = 1;

  /// 当前控制器是否正在驱动仿真触点的二维收尾轨迹。
  bool _simulationMotionActive = false;

  /// 【FLUTTER_READER_SIMULATION_LOG】上一条逐帧几何日志的毫秒时间戳，用于限制文件日志写入频率。
  int _simulationDebugLastFrameLogAtMs = 0;

  /// 【FLUTTER_READER_SIMULATION_LOG】当前分页组件产生的仿真诊断日志递增序号。
  int _simulationDebugSequence = 0;

  /// 卷页手势期间暂缓应用的完整分页结果。
  List<ReaderTextPage>? _pendingCompletePages;

  /// 暂缓分页结果所属的布局签名。
  int? _pendingCompleteSignature;

  /// 暂缓分页结果所属的布局代次。
  int? _pendingCompleteGeneration;

  /// 已完成分页的上一可阅读章节末页预览。
  _ReaderAdjacentPagePreview? _previousChapterPagePreview;

  /// 已完成分页的下一可阅读章节首页预览。
  _ReaderAdjacentPagePreview? _nextChapterPagePreview;

  /// 上一章节页面预览对应的布局签名。
  int? _previousChapterPreviewSignature;

  /// 下一章节页面预览对应的布局签名。
  int? _nextChapterPreviewSignature;

  /// 上一章节页面预览异步任务世代。
  int _previousChapterPreviewGeneration = 0;

  /// 下一章节页面预览异步任务世代。
  int _nextChapterPreviewGeneration = 0;

  /// 上一章节完整末页是否正在后台分批计算。
  bool _previousChapterPreviewLoading = false;

  /// 下一章节首屏是否正在首帧后计算。
  bool _nextChapterPreviewLoading = false;

  /// 当前边界手势使用的相邻章节目标页。
  _ReaderAdjacentPagePreview? _boundaryTargetPreview;

  /// 边界卷页是否已经完成并正在等待 ViewModel 提交新章节。
  bool _boundaryTurnCommitted = false;

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
    _previousChapterPreviewGeneration += 1;
    _nextChapterPreviewGeneration += 1;
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
            (constraints.maxHeight - chromeHeight - _edgeVerticalPadding * 2)
                .clamp(1, double.infinity)
                .toDouble();
        /// 当前系统文字缩放策略。
        final TextScaler textScaler = MediaQuery.textScalerOf(context);
        /// 会影响分页边界的全部稳定输入签名。
        final int layoutSignature = _pageLayoutSignature(
          content: content,
          contentWidth: contentWidth,
          contentHeight: contentHeight,
          textScaler: textScaler,
        );
        if (_layoutSignature != layoutSignature) {
          _layoutSignature = layoutSignature;
          _layoutGeneration += 1;
          _pendingCompletePages = null;
          _pendingCompleteSignature = null;
          _pendingCompleteGeneration = null;
          _coverController.stop();
          _horizontalDragEnabled = false;
          _horizontalDragDirection = 0;
          _horizontalDragCancelRequested = false;
          _coverFromIndex = null;
          _coverToIndex = null;
          _boundaryTargetPreview = null;
          _boundaryTurnCommitted = false;
          _resetSimulationMotion();
          /// 当前签名已经缓存的完整分页结果。
          final List<ReaderTextPage>? cachedPages =
              ReaderPageLayoutCache.get(layoutSignature);
          if (cachedPages != null) {
            _pages = cachedPages;
            _isLayoutComplete = true;
          } else {
            _isLayoutComplete = false;
            /// 首批纯文本页面。
            final List<ReaderTextPage> initialTextPages =
                ReaderPageLayoutEngine.paginate(
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
            _pages = ReaderPageLayoutEngine.insertImagePages(
              pages: initialTextPages,
              images: content.images.where((ReaderContentImage image) {
                if (initialTextPages.isEmpty) {
                  return true;
                }
                return image.characterOffset <= initialTextPages.last.endOffset;
              }).toList(growable: false),
              pageHeight: contentHeight,
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
        _syncAdjacentPagePreviews(
          bodyStyle: textStyle,
          titleStyle: titleStyle,
          contentWidth: contentWidth,
          contentHeight: contentHeight,
          textDirection: Directionality.of(context),
          textScaler: textScaler,
        );
        _restorePage(widget.state);
        if (_usesSimulationPaging) {
          _simulationPageSize = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );
        }
        if (_usesInteractiveHorizontalPaging) {
          return ReaderTapRegion(
            onTapUp: (Offset position) {
              _handleTap(
                position.dx,
                position.dy,
                constraints.maxWidth,
                constraints.maxHeight,
              );
            },
            onSelectionActiveChanged: _handleSelectionActiveChanged,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: _selectionActive
                  ? null
                  : (DragStartDetails details) {
                      if (widget.state.menuVisible) {
                        widget.onIntent(const HideReaderMenuIntent());
                      }
                      _handleHorizontalDragStart(
                        constraints.maxWidth,
                        constraints.maxHeight,
                        details,
                      );
                    },
              onHorizontalDragUpdate: _selectionActive
                  ? null
                  : (DragUpdateDetails details) {
                      _handleHorizontalDragUpdate(
                        details,
                        constraints.maxHeight,
                      );
                    },
              onHorizontalDragEnd:
                  _selectionActive ? null : _handleHorizontalDragEnd,
              onHorizontalDragCancel:
                  _selectionActive ? null : _handleHorizontalDragCancel,
              child: _usesSimulationPaging
                  ? _buildSimulationPager(
                      content,
                      textStyle,
                      titleStyle,
                      contentWidth,
                    )
                  : _buildCoverPager(
                      content,
                      textStyle,
                      titleStyle,
                      contentWidth,
                    ),
            ),
          );
        }
        return NotificationListener<ScrollStartNotification>(
          onNotification: (ScrollStartNotification notification) {
            if (notification.dragDetails != null && widget.state.menuVisible) {
              widget.onIntent(const HideReaderMenuIntent());
            }
            return false;
          },
          child: NotificationListener<OverscrollNotification>(
            onNotification: (OverscrollNotification notification) {
              if (notification.metrics.extentBefore <= 1 &&
                  notification.overscroll < -16 &&
                  widget.state.canGoPrevious) {
                widget.onIntent(const OpenPreviousChapterIntent());
              }
              return false;
            },
            child: ReaderTapRegion(
            onTapUp: (Offset position) {
              _handleTap(
                position.dx,
                position.dy,
                constraints.maxWidth,
                constraints.maxHeight,
              );
            },
            onSelectionActiveChanged: _handleSelectionActiveChanged,
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
      if (_usesSimulationPaging) {
        _simulationGestureStart = Offset(
          _simulationPageSize.width * 0.9,
          _simulationPageSize.height * 0.9,
        );
      }
      _performTapAction(ReaderTapAction.previousPage);
      return;
    }
    if (logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      if (_usesSimulationPaging) {
        _simulationGestureStart = Offset(
          _simulationPageSize.width * 0.9,
          _simulationPageSize.height * 0.9,
        );
      }
      _performTapAction(ReaderTapAction.nextPage);
    }
  }

  /// 当前是否使用覆盖翻页渲染路径。
  bool get _usesCoverPaging {
    return widget.state.config.readingMode == ReaderReadingMode.horizontalPaging &&
        widget.state.config.pageTurnStyle == ReaderPageTurnStyle.cover;
  }

  /// 当前是否使用贝塞尔仿真卷页呈现。
  bool get _usesSimulationPaging {
    return widget.state.config.readingMode ==
            ReaderReadingMode.horizontalPaging &&
        widget.state.config.pageTurnStyle ==
            ReaderPageTurnStyle.simulation;
  }

  /// 当前是否使用由阅读器自己接管的水平跟手动画，而不是 PageView 默认手势。
  bool get _usesInteractiveHorizontalPaging {
    return _usesCoverPaging || _usesSimulationPaging;
  }

  /// 生成与当前完整分页缓存一致的签名，供当前章和相邻章预览共同复用。
  int _pageLayoutSignature({
    required ReaderChapterContent content,
    required double contentWidth,
    required double contentHeight,
    required TextScaler textScaler,
  }) {
    return Object.hashAll(<Object?>[
      content.chapterUrl,
      content.title,
      content.text,
      ...content.images.map(
        (ReaderContentImage image) =>
            '${image.characterOffset}:${image.url}',
      ),
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
  }

  /// 同步前后章正文快照对应的有限页面预览；非仿真模式立即释放可重建结果。
  void _syncAdjacentPagePreviews({
    required TextStyle bodyStyle,
    required TextStyle titleStyle,
    required double contentWidth,
    required double contentHeight,
    required TextDirection textDirection,
    required TextScaler textScaler,
  }) {
    if (!_usesSimulationPaging) {
      _clearAdjacentPagePreviews();
      return;
    }
    _syncNextChapterPagePreview(
      content: widget.state.nextChapterPreview,
      bodyStyle: bodyStyle,
      titleStyle: titleStyle,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
      textDirection: textDirection,
      textScaler: textScaler,
    );
    _syncPreviousChapterPagePreview(
      content: widget.state.previousChapterPreview,
      bodyStyle: bodyStyle,
      titleStyle: titleStyle,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
      textDirection: textDirection,
      textScaler: textScaler,
    );
  }

  /// 为下一可阅读章节生成首个目标页；只测量一页，避免与当前章完整分页竞争。
  void _syncNextChapterPagePreview({
    required ReaderChapterContent? content,
    required TextStyle bodyStyle,
    required TextStyle titleStyle,
    required double contentWidth,
    required double contentHeight,
    required TextDirection textDirection,
    required TextScaler textScaler,
  }) {
    /// 下一章正文当前布局下的稳定签名。
    final int? signature = content == null
        ? null
        : _pageLayoutSignature(
            content: content,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            textScaler: textScaler,
          );
    if (_nextChapterPreviewSignature != signature) {
      _nextChapterPreviewSignature = signature;
      _nextChapterPagePreview = null;
      _nextChapterPreviewLoading = false;
      _nextChapterPreviewGeneration += 1;
    }
    if (content == null ||
        signature == null ||
        _nextChapterPagePreview != null ||
        _nextChapterPreviewLoading) {
      return;
    }
    _nextChapterPreviewLoading = true;
    /// 本次下一章首屏预览任务世代。
    final int generation = _nextChapterPreviewGeneration;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      Future<void>.delayed(Duration.zero).then((_) {
        if (!mounted ||
            generation != _nextChapterPreviewGeneration ||
            _nextChapterPreviewSignature != signature) {
          return;
        }
        try {
          /// 下一章第一页纯文本分页结果。
          final List<ReaderTextPage> textPages =
              ReaderPageLayoutEngine.paginate(
            title: widget.state.config.titleMode == ReaderTitleMode.hidden
                ? ''
                : content.title,
            text: content.text,
            bodyStyle: bodyStyle,
            titleStyle: titleStyle,
            maxWidth: contentWidth,
            maxHeight: contentHeight,
            titleTopSpacing: widget.state.config.titleTopSpacing,
            titleBottomSpacing: widget.state.config.titleBottomSpacing,
            paragraphSpacing: widget.state.config.paragraphSpacing,
            paragraphIndent: widget.state.config.paragraphIndent,
            textFullJustify: widget.state.config.textFullJustify,
            textDirection: textDirection,
            textScaler: textScaler,
            maximumPageCount: 1,
          );
          /// 插入首屏范围图片后的下一章有限页面。
          final List<ReaderTextPage> pages =
              ReaderPageLayoutEngine.insertImagePages(
            pages: textPages,
            images: content.images.where((ReaderContentImage image) {
              if (textPages.isEmpty) {
                return true;
              }
              return image.characterOffset <= textPages.last.endOffset;
            }).toList(growable: false),
            pageHeight: contentHeight,
          );
          if (!mounted ||
              generation != _nextChapterPreviewGeneration ||
              _nextChapterPreviewSignature != signature) {
            return;
          }
          setState(() {
            _nextChapterPreviewLoading = false;
            if (pages.isEmpty) {
              _nextChapterPagePreview = null;
              return;
            }
            /// 下一章实时卷页使用的第一页。
            final ReaderTextPage page = pages.first;
            _nextChapterPagePreview = _ReaderAdjacentPagePreview(
              content: content,
              page: page,
              pageIndex: 0,
              footerText: _adjacentPreviewFooterText(
                content: content,
                page: page,
                pageIndex: 0,
                pageCount: null,
              ),
            );
          });
        } on Object {
          if (mounted &&
              generation == _nextChapterPreviewGeneration &&
              _nextChapterPreviewSignature == signature) {
            setState(() {
              _nextChapterPreviewLoading = false;
              _nextChapterPagePreview = null;
            });
          }
        }
      });
    });
  }

  /// 为上一可阅读章节取得完整分页末页；优先命中三套 LRU，未命中时在当前章完成后分批计算。
  void _syncPreviousChapterPagePreview({
    required ReaderChapterContent? content,
    required TextStyle bodyStyle,
    required TextStyle titleStyle,
    required double contentWidth,
    required double contentHeight,
    required TextDirection textDirection,
    required TextScaler textScaler,
  }) {
    /// 上一章正文当前布局下的稳定签名。
    final int? signature = content == null
        ? null
        : _pageLayoutSignature(
            content: content,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            textScaler: textScaler,
          );
    if (_previousChapterPreviewSignature != signature) {
      _previousChapterPreviewSignature = signature;
      _previousChapterPagePreview = null;
      _previousChapterPreviewLoading = false;
      _previousChapterPreviewGeneration += 1;
    }
    if (content == null || signature == null) {
      return;
    }
    if (_previousChapterPagePreview == null) {
      /// 上一章已经存在的完整分页 LRU。
      final List<ReaderTextPage>? cachedPages =
          ReaderPageLayoutCache.get(signature);
      if (cachedPages != null && cachedPages.isNotEmpty) {
        /// 上一章末页在完整页集中的索引。
        final int pageIndex = cachedPages.length - 1;
        /// 上一章实时卷页使用的末页。
        final ReaderTextPage page = cachedPages[pageIndex];
        _previousChapterPagePreview = _ReaderAdjacentPagePreview(
          content: content,
          page: page,
          pageIndex: pageIndex,
          footerText: _adjacentPreviewFooterText(
            content: content,
            page: page,
            pageIndex: pageIndex,
            pageCount: cachedPages.length,
          ),
        );
      }
    }
    if (_previousChapterPagePreview != null ||
        _previousChapterPreviewLoading ||
        !_isLayoutComplete) {
      return;
    }
    _previousChapterPreviewLoading = true;
    /// 本次上一章末页后台任务世代。
    final int generation = _previousChapterPreviewGeneration;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      Future<void>.delayed(Duration.zero).then((_) async {
        if (!mounted ||
            generation != _previousChapterPreviewGeneration ||
            _previousChapterPreviewSignature != signature) {
          return;
        }
        try {
          /// 上一章完整分页的分批测量任务。
          final _ReaderIncrementalPageLayoutJob layoutJob =
              _ReaderIncrementalPageLayoutJob(
            title: widget.state.config.titleMode == ReaderTitleMode.hidden
                ? ''
                : content.title,
            text: content.text,
            bodyStyle: bodyStyle,
            titleStyle: titleStyle,
            maxWidth: contentWidth,
            maxHeight: contentHeight,
            titleTopSpacing: widget.state.config.titleTopSpacing,
            titleBottomSpacing: widget.state.config.titleBottomSpacing,
            paragraphSpacing: widget.state.config.paragraphSpacing,
            paragraphIndent: widget.state.config.paragraphIndent,
            textFullJustify: widget.state.config.textFullJustify,
            textDirection: textDirection,
            textScaler: textScaler,
          );
          /// 上一章完整纯文本页集。
          final List<ReaderTextPage> textPages = await layoutJob.run();
          /// 插入图片页后的上一章完整页集。
          final List<ReaderTextPage> pages =
              ReaderPageLayoutEngine.insertImagePages(
            pages: textPages,
            images: content.images,
            pageHeight: contentHeight,
          );
          if (!mounted ||
              generation != _previousChapterPreviewGeneration ||
              _previousChapterPreviewSignature != signature) {
            return;
          }
          ReaderPageLayoutCache.put(signature, pages);
          setState(() {
            _previousChapterPreviewLoading = false;
            if (pages.isEmpty) {
              _previousChapterPagePreview = null;
              return;
            }
            /// 上一章末页在完整页集中的索引。
            final int pageIndex = pages.length - 1;
            /// 上一章实时卷页使用的末页。
            final ReaderTextPage page = pages[pageIndex];
            _previousChapterPagePreview = _ReaderAdjacentPagePreview(
              content: content,
              page: page,
              pageIndex: pageIndex,
              footerText: _adjacentPreviewFooterText(
                content: content,
                page: page,
                pageIndex: pageIndex,
                pageCount: pages.length,
              ),
            );
          });
        } on Object {
          if (mounted &&
              generation == _previousChapterPreviewGeneration &&
              _previousChapterPreviewSignature == signature) {
            setState(() {
              _previousChapterPreviewLoading = false;
              _previousChapterPagePreview = null;
            });
          }
        }
      });
    });
  }

  /// 清理相邻章节可重建页面和异步世代，不影响当前稳定正文。
  void _clearAdjacentPagePreviews() {
    _previousChapterPreviewGeneration += 1;
    _nextChapterPreviewGeneration += 1;
    _previousChapterPreviewSignature = null;
    _nextChapterPreviewSignature = null;
    _previousChapterPagePreview = null;
    _nextChapterPagePreview = null;
    _previousChapterPreviewLoading = false;
    _nextChapterPreviewLoading = false;
    _boundaryTargetPreview = null;
    _boundaryTurnCommitted = false;
  }

  /// 构建相邻章节目标页页脚；下一章总页数未知时使用省略号。
  String _adjacentPreviewFooterText({
    required ReaderChapterContent content,
    required ReaderTextPage page,
    required int pageIndex,
    required int? pageCount,
  }) {
    /// 当前目标页结束位置对应的章节百分比。
    final int percent = content.text.isEmpty
        ? 0
        : ((page.endOffset / content.text.length).clamp(0, 1) * 100)
            .round();
    /// 已知完整分页时显示真实总页数，否则保持省略号。
    final String totalText = pageCount == null ? '…' : '$pageCount';
    return '${pageIndex + 1} / $totalText · $percent%';
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
        /// 完整纯文本分页结果。
        final List<ReaderTextPage> completeTextPages = await layoutJob.run();
        /// 插入独立图片页后的完整章节分页结果。
        final List<ReaderTextPage> completePages =
            ReaderPageLayoutEngine.insertImagePages(
              pages: completeTextPages,
              images: content.images,
              pageHeight: contentHeight,
            );
        ReaderPageLayoutCache.put(signature, completePages);
        if (!mounted ||
            _layoutSignature != signature ||
            _layoutGeneration != generation) {
          return;
        }
        if (_horizontalDragEnabled || _coverController.isAnimating) {
          _pendingCompletePages = completePages;
          _pendingCompleteSignature = signature;
          _pendingCompleteGeneration = generation;
          return;
        }
        _applyCompletePagination(
          completePages,
          signature: signature,
          generation: generation,
        );
      });
    });
  }

  /// 应用仍属于当前布局代次的完整分页，并按可见字符位置保持页码稳定。
  void _applyCompletePagination(
    List<ReaderTextPage> completePages, {
    required int signature,
    required int generation,
  }) {
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
      _selectionEpoch += 1;
      _selectionActive = false;
      _coverFromIndex = null;
      _coverToIndex = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (!mounted || !_pageController.hasClients) {
        return;
      }
      _pageController.jumpToPage(_currentPageIndex);
    });
  }

  /// 在卷页提交或回弹结束后应用暂缓的完整分页结果。
  void _applyPendingCompletePagination() {
    /// 等待应用的完整页集。
    final List<ReaderTextPage>? completePages = _pendingCompletePages;
    /// 页集所属布局签名。
    final int? signature = _pendingCompleteSignature;
    /// 页集所属布局代次。
    final int? generation = _pendingCompleteGeneration;
    _pendingCompletePages = null;
    _pendingCompleteSignature = null;
    _pendingCompleteGeneration = null;
    if (completePages == null || signature == null || generation == null) {
      return;
    }
    _applyCompletePagination(
      completePages,
      signature: signature,
      generation: generation,
    );
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

  /// 构建贝塞尔仿真卷页内容栈；空闲时只保留当前可选择正文页。
  Widget _buildSimulationPager(
    ReaderChapterContent content,
    TextStyle textStyle,
    TextStyle titleStyle,
    double contentWidth,
  ) {
    if (_pages.isEmpty) {
      return const SizedBox.shrink();
    }
    /// 仿真动画开始前的当前页面索引。
    final int baseIndex = (_coverFromIndex ?? _currentPageIndex)
        .clamp(0, _pages.length - 1)
        .toInt();
    /// 仿真动画的目标页面索引。
    final int? targetIndex = _coverToIndex;
    /// 当前边界手势已经准备好的相邻章节目标页。
    final _ReaderAdjacentPagePreview? boundaryPreview =
        _boundaryTargetPreview;
    if (boundaryPreview == null &&
        (targetIndex == null ||
            targetIndex < 0 ||
            targetIndex >= _pages.length)) {
      return _buildPage(
        content,
        textStyle,
        titleStyle,
        contentWidth,
        baseIndex,
        _pages[baseIndex],
      );
    }
    /// 动画期间当前页禁用重复选区和语义节点。
    final Widget currentPage = _buildPage(
      content,
      textStyle,
      titleStyle,
      contentWidth,
      baseIndex,
      _pages[baseIndex],
      selectionEnabled: false,
    );
    /// 动画目标正文。
    final ReaderChapterContent targetContent;
    /// 动画目标分页模型。
    final ReaderTextPage targetPageModel;
    /// 动画目标页在其章节内的索引。
    final int targetPageIndex;
    /// 动画目标页页脚覆盖文本；章内目标页保持为空。
    final String? targetFooterText;
    /// 目标页是否允许消费当前章节标注；跨章预览必须禁用。
    final bool includeCurrentProcesses;
    if (boundaryPreview != null) {
      targetContent = boundaryPreview.content;
      targetPageModel = boundaryPreview.page;
      targetPageIndex = boundaryPreview.pageIndex;
      targetFooterText = boundaryPreview.footerText;
      includeCurrentProcesses = false;
    } else if (targetIndex != null &&
        targetIndex >= 0 &&
        targetIndex < _pages.length) {
      targetContent = content;
      targetPageModel = _pages[targetIndex];
      targetPageIndex = targetIndex;
      targetFooterText = null;
      includeCurrentProcesses = true;
    } else {
      return currentPage;
    }
    /// 动画期间目标页禁用重复选区和语义节点。
    final Widget targetPage = _buildPage(
      targetContent,
      textStyle,
      titleStyle,
      contentWidth,
      targetPageIndex,
      targetPageModel,
      selectionEnabled: false,
      includeCurrentProcesses: includeCurrentProcesses,
      footerText: targetFooterText,
    );
    return AnimatedBuilder(
      animation: _coverController,
      builder: (BuildContext context, Widget? child) {
        return ReaderSimulationPageTurnFrame(
          currentPage: currentPage,
          targetPage: targetPage,
          direction: _coverDirection,
          progress: _coverController.value,
          touch: _simulationTouchForControllerValue(
            _coverController.value,
          ),
          corner: _simulationCorner,
          paperColor: Color(widget.state.config.backgroundColorValue),
          onDebugLog: _writeSimulationDebugLog,
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
    ReaderTextPage page, {
    bool selectionEnabled = true,
    bool includeCurrentProcesses = true,
    String? footerText,
  }) {
    return ColoredBox(
      color: Color(widget.state.config.backgroundColorValue),
      child: Center(
        child: SizedBox(
          width: contentWidth,
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: _edgeVerticalPadding,
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
                  child: _buildPageLines(
                    content,
                    page,
                    textStyle,
                    titleStyle,
                    index,
                    selectionEnabled: selectionEnabled,
                    includeCurrentProcesses: includeCurrentProcesses,
                  ),
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
                          footerText ?? _pageFooterText(index, page),
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
    ReaderChapterContent content,
    ReaderTextPage page,
    TextStyle bodyStyle,
    TextStyle titleStyle,
    int pageIndex, {
    required bool selectionEnabled,
    required bool includeCurrentProcesses,
  }) {
    /// 当前页是否包含至少一行可选择正文。
    final bool hasSelectableBody = page.lines.any(
      (ReaderPageLine line) =>
          line.kind == ReaderPageLineKind.body &&
          line.endOffset > line.startOffset,
    );
    /// 按分页测量结果生成的行布局。
    final Widget lines = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: page.lines.map((ReaderPageLine line) {
        if (line.kind == ReaderPageLineKind.spacer) {
          return SizedBox(height: line.height);
        }
        if (line.kind == ReaderPageLineKind.image) {
          /// 分页图片为工具按钮和页面边缘保留少量垂直空间。
          final double imageHeight = (line.height - SpacingToken.medium * 2)
              .clamp(1, line.height)
              .toDouble();
          return ReaderContentImageView(
            imageUrl: line.text,
            altText: line.altText,
            referer: line.referer,
            maximumHeight: imageHeight,
            onSave: () => widget.onIntent(
              ShareReaderContentImageIntent(line.text),
            ),
          );
        }
        if (line.kind == ReaderPageLineKind.title) {
          return SizedBox(
            height: line.height,
            child: SelectionContainer.disabled(
              child: Text(
                line.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: titleStyle,
                textAlign: widget.state.config.titleMode ==
                        ReaderTitleMode.center
                    ? TextAlign.center
                    : TextAlign.start,
              ),
            ),
          );
        }
        /// 当前正文行合并两端对齐补偿后的基础样式。
        final TextStyle style = bodyStyle.copyWith(
                letterSpacing: (bodyStyle.letterSpacing ?? 0) +
                    line.extraLetterSpacing,
                wordSpacing: (bodyStyle.wordSpacing ?? 0) +
                    line.extraWordSpacing,
              );
        /// 当前正文行在章节内的有效终点，排除只用于进度的段尾换行。
        int sourceEnd = line.endOffset
            .clamp(line.startOffset, content.text.length)
            .toInt();
        if (sourceEnd > line.startOffset &&
            content.text[sourceEnd - 1] == '\n') {
          sourceEnd -= 1;
        }
        /// 当前正文行与章节字符位置一一对应的原始文本。
        final String sourceText = content.text.substring(
          line.startOffset.clamp(0, sourceEnd).toInt(),
          sourceEnd,
        );
        /// 首行全角缩进等只参与显示、不进入章节锚点的前缀。
        final String displayPrefix = line.text.endsWith(sourceText)
            ? line.text.substring(0, line.text.length - sourceText.length)
            : '';
        return SizedBox(
          height: line.height,
          child: Text.rich(
            TextSpan(
              children: <InlineSpan>[
                if (displayPrefix.isNotEmpty)
                  TextSpan(text: displayPrefix, style: style),
                ...buildReaderAnnotationSpans(
                  chapterText: content.text,
                  text: sourceText,
                  startOffset: line.startOffset,
                  baseStyle: style,
                  processes: includeCurrentProcesses
                      ? widget.state.contentProcesses
                      : const <BookContentProcess>[],
                ),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            textAlign: TextAlign.start,
          ),
        );
      }).toList(growable: false),
    );
    if (!hasSelectableBody || !selectionEnabled) {
      return lines;
    }
    return ReaderSelectionRegion(
      chapterText: content.text,
      scopeStart: page.startOffset,
      scopeEnd: page.endOffset,
      preferredOffset:
          widget.state.anchor?.characterOffset ?? page.startOffset,
      selectionEpoch: Object.hash(
        widget.state.restoreRequestId,
        _selectionEpoch,
        pageIndex,
      ),
      onAction: (
        ReaderTextSelection selection,
        ReaderSelectionAction action,
      ) {
        widget.onIntent(ApplyReaderSelectionIntent(selection, action));
      },
      child: lines,
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
    setState(() {
      _currentPageIndex = index;
      _selectionEpoch += 1;
      _selectionActive = false;
    });
    widget.onIntent(UpdateReaderScrollIntent(_pages[index].startOffset));
  }

  /// 按用户配置把正文点击区域映射为阅读动作。
  void _handleTap(
    double x,
    double y,
    double width,
    double height,
  ) {
    if (_usesSimulationPaging && width > 0 && height > 0) {
      _simulationPageSize = Size(width, height);
      _simulationGestureStart = Offset(x, y);
    }
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

  /// 同步原生文字选区状态，并在选区存在时移除外层横向手势识别器。
  void _handleSelectionActiveChanged(bool active) {
    if (!mounted || _selectionActive == active) {
      return;
    }
    setState(() {
      _selectionActive = active;
    });
  }

  /// 执行正文点击和按键共享的阅读动作；正文长按固定交给原生选区。
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
    if (_usesInteractiveHorizontalPaging && _currentPageIndex > 0) {
      _turnToPage(_currentPageIndex - 1);
      return;
    }
    if (_pageController.hasClients && (_pageController.page ?? 0) > 0) {
      _turnToPage((_pageController.page ?? 0).round() - 1);
      return;
    }
    if (_usesSimulationPaging &&
        _isLayoutComplete &&
        _previousChapterPagePreview != null) {
      _animateAdjacentChapterPreview(-1);
      return;
    }
    if (_isLayoutComplete && widget.state.canGoPrevious) {
      widget.onIntent(const OpenPreviousChapterIntent());
    }
  }

  /// 优先翻到当前章节下一页，到达边界后进入下一章。
  void _openNextPageOrChapter() {
    if (_usesInteractiveHorizontalPaging &&
        _currentPageIndex < _pages.length - 1) {
      _turnToPage(_currentPageIndex + 1);
      return;
    }
    if (_pageController.hasClients &&
        (_pageController.page ?? 0) < _pages.length - 1) {
      _turnToPage((_pageController.page ?? 0).round() + 1);
      return;
    }
    if (_usesSimulationPaging &&
        _isLayoutComplete &&
        _nextChapterPagePreview != null) {
      _animateAdjacentChapterPreview(1);
      return;
    }
    if (_isLayoutComplete && widget.state.canGoNext) {
      widget.onIntent(const OpenNextChapterIntent());
    }
  }

  /// 返回指定方向已经完成分页的相邻章节目标页。
  _ReaderAdjacentPagePreview? _adjacentPreviewForDirection(int direction) {
    if (!_isLayoutComplete) {
      return null;
    }
    return direction < 0
        ? _previousChapterPagePreview
        : _nextChapterPagePreview;
  }

  /// 点击区域或音量键在章边界时使用相邻预览页播放同一套程序化仿真。
  void _animateAdjacentChapterPreview(int direction) {
    if (_coverController.isAnimating || _boundaryTurnCommitted) {
      return;
    }
    /// 当前方向已经准备好的相邻章节页面。
    final _ReaderAdjacentPagePreview? preview =
        _adjacentPreviewForDirection(direction);
    if (preview == null) {
      return;
    }
    _prepareProgrammaticSimulation(direction);
    setState(() {
      _coverFromIndex = _currentPageIndex;
      _coverToIndex = null;
      _coverDirection = direction;
      _boundaryTargetPreview = preview;
    });
    _coverController.reset();
    _finishAdjacentChapterAnimation(direction);
  }

  /// 开始横向跟手翻页，并记录页面尺寸和仿真触点。
  void _handleHorizontalDragStart(
    double width,
    double height,
    DragStartDetails details,
  ) {
    _horizontalDragEnabled =
        !_selectionActive &&
        !_coverController.isAnimating &&
        !_boundaryTurnCommitted;
    if (!_horizontalDragEnabled) {
      return;
    }
    _horizontalDragDistance = 0;
    _horizontalDragWidth = width <= 0 ? 1 : width;
    _horizontalDragDirection = 0;
    _horizontalDragCancelRequested = false;
    if (_usesSimulationPaging && width > 0 && height > 0) {
      _simulationPageSize = Size(width, height);
      _simulationGestureStart = details.localPosition;
      _simulationTouch = details.localPosition;
      _simulationCorner = Offset(width, height);
      _resetSimulationMotion();
      _writeSimulationDebugLog(
        'event=drag_start size=$_simulationPageSize '
        'start=$_simulationGestureStart',
        force: true,
      );
    }
  }

  /// 根据手指真实二维位置更新覆盖或仿真目标页，并在首次有效移动后锁定方向。
  void _handleHorizontalDragUpdate(
    DragUpdateDetails details,
    double height,
  ) {
    if (!_horizontalDragEnabled || _coverController.isAnimating || _pages.isEmpty) {
      return;
    }
    _horizontalDragDistance += details.delta.dx;
    if (_horizontalDragDistance == 0) {
      return;
    }
    if (_horizontalDragDirection == 0) {
      _horizontalDragDirection = _horizontalDragDistance < 0 ? 1 : -1;
      if (_usesSimulationPaging) {
        _lockSimulationCorner(_horizontalDragDirection);
        _writeSimulationDebugLog(
          'event=direction_lock direction=$_horizontalDragDirection '
          'distance=${_horizontalDragDistance.toStringAsFixed(1)} '
          'start=$_simulationGestureStart corner=$_simulationCorner',
          force: true,
        );
      }
    }
    /// 本次手势已经锁定的目标方向，不因回拉穿过起点而更换页面。
    final int direction = _horizontalDragDirection;
    _horizontalDragCancelRequested =
        direction > 0 ? details.delta.dx > 0 : details.delta.dx < 0;
    if (_usesSimulationPaging && height > 0) {
      _simulationTouch = _adjustSimulationDragTouch(
        details.localPosition,
        direction,
      );
    }
    /// 当前章节内与手势方向对应的目标页索引。
    final int targetIndex = _currentPageIndex + direction;
    if (targetIndex < 0 || targetIndex >= _pages.length) {
      /// 当前方向已经完成后台分页的相邻章节目标页。
      final _ReaderAdjacentPagePreview? adjacentPreview =
          _adjacentPreviewForDirection(direction);
      if (!_usesSimulationPaging || adjacentPreview == null) {
        if (_coverToIndex != null || _boundaryTargetPreview != null) {
          setState(() {
            _coverFromIndex = null;
            _coverToIndex = null;
            _boundaryTargetPreview = null;
          });
          _coverController.value = 0;
        }
        return;
      }
      if (!identical(_boundaryTargetPreview, adjacentPreview)) {
        setState(() {
          _coverFromIndex = _currentPageIndex;
          _coverToIndex = null;
          _coverDirection = direction;
          _boundaryTargetPreview = adjacentPreview;
        });
        _coverController.value = 0;
      }
    } else if (_coverToIndex != targetIndex ||
        _boundaryTargetPreview != null) {
      setState(() {
        _coverFromIndex = _currentPageIndex;
        _coverToIndex = targetIndex;
        _coverDirection = direction;
        _boundaryTargetPreview = null;
      });
      _coverController.value = 0;
    }
    /// 当前拖动距离沿锁定方向的完成比例；回拉穿过起点后保持在零而不切换目标页。
    final double directedDistance = direction > 0
        ? -_horizontalDragDistance
        : _horizontalDragDistance;
    /// 当前拖动距离对应的受控页面完成比例。
    final double progress =
        (directedDistance / _horizontalDragWidth).clamp(0, 1).toDouble();
    /// 目标页存在时保留极小首尾余量，确保真实触点仍可执行完成或回弹二维收尾。
    _coverController.value = progress.clamp(0.002, 0.998).toDouble();
  }

  /// 系统取消当前横向手势时按原方向回弹，并保留当前字符锚点。
  void _handleHorizontalDragCancel() {
    if (!_horizontalDragEnabled) {
      return;
    }
    _horizontalDragEnabled = false;
    _horizontalDragDistance = 0;
    if (_coverToIndex != null) {
      _cancelCoverAnimation();
      return;
    }
    _horizontalDragDirection = 0;
    _horizontalDragCancelRequested = false;
    _applyPendingCompletePagination();
  }

  /// 按当前策略决定完成、回弹，或在章节边界进入相邻章节。
  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (!_horizontalDragEnabled || _pages.isEmpty) {
      return;
    }
    _horizontalDragEnabled = false;
    if (_horizontalDragDirection == 0) {
      _horizontalDragDistance = 0;
      _applyPendingCompletePagination();
      return;
    }
    /// 本次手势已经锁定的翻页方向。
    final int direction = _horizontalDragDirection;
    /// 水平结束速度，正数向右、负数向左。
    final double velocity = details.primaryVelocity ?? 0;
    /// 仿真模式按 Android 最后运动方向决定完成/取消；覆盖模式保留原有距离和速度阈值。
    final bool shouldCommit = _usesSimulationPaging
        ? !_horizontalDragCancelRequested
        : _horizontalDragDistance.abs() >=
                _horizontalDragWidth * 0.22 ||
            (direction > 0 ? velocity < -500 : velocity > 500);
    if (_usesSimulationPaging) {
      _writeSimulationDebugLog(
        'event=drag_end direction=$direction commit=$shouldCommit '
        'cancelRequested=$_horizontalDragCancelRequested '
        'distance=${_horizontalDragDistance.toStringAsFixed(1)} '
        'velocity=${velocity.toStringAsFixed(1)} '
        'progress=${_coverController.value.toStringAsFixed(3)} '
        'touch=$_simulationTouch corner=$_simulationCorner '
        'targetIndex=$_coverToIndex boundary=${_boundaryTargetPreview != null}',
        force: true,
      );
    }
    /// 当前手势已经取得的相邻章节目标页。
    final _ReaderAdjacentPagePreview? boundaryPreview =
        _boundaryTargetPreview;
    if (boundaryPreview != null) {
      if (shouldCommit) {
        _finishAdjacentChapterAnimation(direction);
      } else {
        _cancelCoverAnimation();
      }
      _horizontalDragDistance = 0;
      return;
    }
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
    _horizontalDragDirection = 0;
    _horizontalDragCancelRequested = false;
    _applyPendingCompletePagination();
  }

  /// 按 Android 规则为首次有效移动锁定页角：下一页取右上/右下，上一页固定右下。
  void _lockSimulationCorner(int direction) {
    /// 当前仿真页面宽度。
    final double width = _simulationPageSize.width;
    /// 当前仿真页面高度。
    final double height = _simulationPageSize.height;
    if (width <= 0 || height <= 0) {
      return;
    }
    if (direction < 0) {
      _simulationCorner = Offset(width, height);
      return;
    }
    /// Android 下一页以起手点所在上下半屏选择右上或右下页角。
    final bool useUpperCorner = _simulationGestureStart.dy <= height / 2;
    _simulationCorner = Offset(
      width,
      useUpperCorner ? 0 : height,
    );
  }

  /// 对齐 Android 中部触点修正规则，避免中线手势产生过长对角折痕。
  Offset _adjustSimulationDragTouch(Offset rawTouch, int direction) {
    /// 当前仿真页面高度。
    final double height = _simulationPageSize.height;
    if (height <= 0) {
      return rawTouch;
    }
    if (direction < 0) {
      return Offset(rawTouch.dx, height);
    }
    /// 本次手势锁定方向前记录的起手纵坐标。
    final double startY = _simulationGestureStart.dy;
    if (startY > height / 3 && startY < height / 2) {
      return Offset(rawTouch.dx, 1);
    }
    if (startY > height / 3 && startY < height * 2 / 3) {
      return Offset(rawTouch.dx, height);
    }
    return rawTouch;
  }

  /// 为点击区域或音量键翻页准备 Android 同类程序化起点和锁定页角。
  void _prepareProgrammaticSimulation(int direction) {
    /// 当前仿真页面宽度。
    final double width = _simulationPageSize.width;
    /// 当前仿真页面高度。
    final double height = _simulationPageSize.height;
    if (width <= 0 || height <= 0) {
      return;
    }
    _resetSimulationMotion();
    if (direction < 0) {
      _simulationCorner = Offset(width, height);
      _simulationTouch = Offset(0, height);
      _writeSimulationDebugLog(
        'event=programmatic_prepare direction=$direction '
        'size=$_simulationPageSize start=$_simulationGestureStart '
        'touch=$_simulationTouch corner=$_simulationCorner',
        force: true,
      );
      return;
    }
    /// 程序化下一页仍按最近点击所在上下半屏选择页角。
    final bool useUpperCorner = _simulationGestureStart.dy <= height / 2;
    _simulationCorner = Offset(
      width,
      useUpperCorner ? 0 : height,
    );
    _simulationTouch = Offset(
      width * 0.9,
      useUpperCorner ? 1 : height * 0.9,
    );
    _writeSimulationDebugLog(
      'event=programmatic_prepare direction=$direction '
      'size=$_simulationPageSize start=$_simulationGestureStart '
      'touch=$_simulationTouch corner=$_simulationCorner',
      force: true,
    );
  }

  /// 配置从当前真实触点到完成或回弹终点的二维线性插值。
  void _configureSimulationMotion({
    required Offset endTouch,
    required double endValue,
  }) {
    _simulationMotionStartTouch = _simulationTouch;
    _simulationMotionEndTouch = endTouch;
    _simulationMotionStartValue = _coverController.value;
    _simulationMotionEndValue = endValue;
    _simulationMotionActive = true;
    _writeSimulationDebugLog(
      'event=settle_config direction=$_coverDirection '
      'startTouch=$_simulationMotionStartTouch endTouch=$endTouch '
      'startValue=${_simulationMotionStartValue.toStringAsFixed(3)} '
      'endValue=${endValue.toStringAsFixed(3)}',
      force: true,
    );
  }

  /// 返回控制器当前值对应的二维触点，横纵坐标在收尾期间同时抵达目标。
  Offset _simulationTouchForControllerValue(double controllerValue) {
    if (!_simulationMotionActive) {
      return _simulationTouch;
    }
    /// 当前二维插值覆盖的控制器值范围。
    final double valueRange =
        _simulationMotionEndValue - _simulationMotionStartValue;
    if (valueRange.abs() < 0.0001) {
      return _simulationMotionEndTouch;
    }
    /// 当前控制器值在线性收尾轨迹中的比例。
    final double motionProgress =
        ((controllerValue - _simulationMotionStartValue) / valueRange)
            .clamp(0, 1)
            .toDouble();
    return Offset(
      _simulationMotionStartTouch.dx +
          (_simulationMotionEndTouch.dx -
                  _simulationMotionStartTouch.dx) *
              motionProgress,
      _simulationMotionStartTouch.dy +
          (_simulationMotionEndTouch.dy -
                  _simulationMotionStartTouch.dy) *
              motionProgress,
    );
  }

  /// 计算 Android 仿真模式完成或取消时的二维触点终点。
  Offset _simulationSettleEndTouch({required bool commit}) {
    /// 当前仿真页面宽度。
    final double width = _simulationPageSize.width;
    /// 当前仿真页面高度。
    final double height = _simulationPageSize.height;
    /// 上页角使用一个逻辑像素而不是精确零，避免贝塞尔退化。
    final double cornerY = _simulationCorner.dy <= height / 2 ? 1 : height;
    if (_coverDirection > 0) {
      return commit
          ? Offset(-width, cornerY)
          : Offset(width, cornerY);
    }
    return commit
        ? Offset(width, height)
        : Offset(-width, height);
  }

  /// 按 Android 300ms 基准和剩余水平距离计算本段收尾动画时长。
  Duration _simulationSettleDuration(Offset endTouch) {
    /// 防止零尺寸布局产生除零的安全页面宽度。
    final double width =
        _simulationPageSize.width <= 0 ? 1 : _simulationPageSize.width;
    /// 剩余横向距离相对页面宽度的比例。
    final double distanceRatio =
        (endTouch.dx - _simulationTouch.dx).abs() / width;
    /// Android 同类距离时长，限制异常扩展坐标造成的超长动画。
    final int milliseconds =
        (300 * distanceRatio).round().clamp(1, 900).toInt();
    return Duration(milliseconds: milliseconds);
  }

  /// 清理仅属于上一段仿真收尾动画的插值状态。
  void _resetSimulationMotion() {
    _simulationMotionActive = false;
    _simulationMotionStartTouch = _simulationTouch;
    _simulationMotionEndTouch = _simulationTouch;
    _simulationMotionStartValue = _coverController.value;
    _simulationMotionEndValue = _coverController.value;
  }

  /// 【FLUTTER_READER_SIMULATION_LOG】按统一 Tag 写入不含正文的仿真手势和几何日志。
  void _writeSimulationDebugLog(String message, {bool force = false}) {
    if (!_usesSimulationPaging) {
      return;
    }
    /// 【FLUTTER_READER_SIMULATION_LOG】当前毫秒时间戳，用于把逐帧几何日志限制为约每 120ms 一条。
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force && nowMs - _simulationDebugLastFrameLogAtMs < 120) {
      return;
    }
    _simulationDebugLastFrameLogAtMs = nowMs;
    _simulationDebugSequence += 1;
    widget.logger.debug(
      tag: readerSimulationPageTurnLogTag,
      message: 'marker=$readerSimulationPageTurnDebugLogMarker '
          'seq=$_simulationDebugSequence $message',
    );
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
    if (_usesInteractiveHorizontalPaging) {
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

  /// 使用当前自定义覆盖或仿真动画切换到目标页面。
  void _animateCoverToPage(int index) {
    if (_pages.isEmpty || _coverController.isAnimating) {
      return;
    }
    /// 目标页索引。
    final int targetIndex = index.clamp(0, _pages.length - 1).toInt();
    if (targetIndex == _currentPageIndex) {
      return;
    }
    /// 本次程序化翻页方向。
    final int direction = targetIndex > _currentPageIndex ? 1 : -1;
    if (_usesSimulationPaging) {
      _prepareProgrammaticSimulation(direction);
    }
    setState(() {
      _coverFromIndex = _currentPageIndex;
      _coverToIndex = targetIndex;
      _coverDirection = direction;
    });
    _coverController.reset();
    _finishCoverAnimation(targetIndex);
  }

  /// 从当前动画进度完成覆盖或仿真翻页并保存目标页稳定字符锚点。
  void _finishCoverAnimation(int targetIndex) {
    /// 动画开始时的布局代次，防止切章或重排后的旧回调提交页码。
    final int animationGeneration = _layoutGeneration;
    /// 当前覆盖翻页动画任务。
    final Future<void> animation;
    if (_usesSimulationPaging) {
      /// Android 同类完成轨迹的二维终点。
      final Offset endTouch =
          _simulationSettleEndTouch(commit: true);
      _configureSimulationMotion(
        endTouch: endTouch,
        endValue: 1,
      );
      animation = _coverController.animateTo(
        1,
        duration: _simulationSettleDuration(endTouch),
        curve: Curves.linear,
      );
    } else {
      animation = _coverController.forward();
    }
    animation.whenComplete(() {
      if (!mounted ||
          animationGeneration != _layoutGeneration ||
          targetIndex < 0 ||
          targetIndex >= _pages.length) {
        return;
      }
      setState(() {
        _currentPageIndex = targetIndex;
        _selectionEpoch += 1;
        _selectionActive = false;
        _coverFromIndex = null;
        _coverToIndex = null;
        _boundaryTargetPreview = null;
        _boundaryTurnCommitted = false;
        _horizontalDragDirection = 0;
        _horizontalDragCancelRequested = false;
        _resetSimulationMotion();
      });
      widget.onIntent(UpdateReaderScrollIntent(_pages[targetIndex].startOffset));
      _applyPendingCompletePagination();
    });
  }

  /// 完成章首或章末的同一次仿真手势，并在视觉到位后提交相邻章节。
  void _finishAdjacentChapterAnimation(int direction) {
    /// 动画开始时的布局代次，防止旧边界回调在重排后提交章节。
    final int animationGeneration = _layoutGeneration;
    /// Android 同类完成轨迹的二维终点。
    final Offset endTouch = _simulationSettleEndTouch(commit: true);
    _configureSimulationMotion(
      endTouch: endTouch,
      endValue: 1,
    );
    /// 当前跨章节边界仿真动画任务。
    final Future<void> animation = _coverController.animateTo(
      1,
      duration: _simulationSettleDuration(endTouch),
      curve: Curves.linear,
    );
    animation.whenComplete(() {
      if (!mounted ||
          animationGeneration != _layoutGeneration ||
          _boundaryTargetPreview == null) {
        return;
      }
      setState(() {
        _selectionEpoch += 1;
        _selectionActive = false;
        _boundaryTurnCommitted = true;
        _horizontalDragDirection = 0;
        _horizontalDragCancelRequested = false;
        _resetSimulationMotion();
      });
      widget.onIntent(
        CommitReaderAdjacentPageTurnIntent(direction),
      );
    });
  }

  /// 将未达到阈值的覆盖页退回屏幕外，并清理本地手势状态。
  void _cancelCoverAnimation() {
    /// 当前覆盖页回弹任务。
    final Future<void> animation;
    if (_usesSimulationPaging) {
      /// Android 同类回弹轨迹的二维终点。
      final Offset endTouch =
          _simulationSettleEndTouch(commit: false);
      _configureSimulationMotion(
        endTouch: endTouch,
        endValue: 0,
      );
      animation = _coverController.animateTo(
        0,
        duration: _simulationSettleDuration(endTouch),
        curve: Curves.linear,
      );
    } else {
      animation = _coverController.reverse();
    }
    animation.whenComplete(() {
      if (!mounted) {
        return;
      }
      setState(() {
        _coverFromIndex = null;
        _coverToIndex = null;
        _boundaryTargetPreview = null;
        _boundaryTurnCommitted = false;
        _horizontalDragDirection = 0;
        _horizontalDragCancelRequested = false;
        _resetSimulationMotion();
      });
      _applyPendingCompletePagination();
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

/// 保存一个相邻章节已经完成测量的有限目标页，不持有额外 Widget、控制器或平台资源。
final class _ReaderAdjacentPagePreview {
  /// 创建章首或章末卷页所需的只读页面快照。
  const _ReaderAdjacentPagePreview({
    required this.content,
    required this.page,
    required this.pageIndex,
    required this.footerText,
  });

  /// 目标章节已经处理完成的正文。
  final ReaderChapterContent content;

  /// 目标章节首个或最后一个分页模型。
  final ReaderTextPage page;

  /// 目标页在相邻章节完整页集中的索引。
  final int pageIndex;

  /// 目标页独立页脚，避免读取当前章节页数和百分比。
  final String footerText;
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
