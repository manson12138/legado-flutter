/// 用户正文标注类型，对应 Android `BookContentProcess` 的用户高亮与下划线类型。
enum BookContentProcessKind {
  /// 使用背景色强调选区。
  userHighlight,

  /// 使用下划线强调选区。
  userUnderline,
}

/// 阅读选区上下文菜单交给 ViewModel 的业务动作。
enum ReaderSelectionAction {
  /// 使用选区原文创建书签。
  bookmark,

  /// 创建背景色高亮标注。
  highlight,

  /// 创建下划线标注。
  underline,
}

/// 提供正文标注类型与 Android 持久化字符串之间的稳定映射。
extension BookContentProcessKindStorage on BookContentProcessKind {
  /// 返回 Android `BookContentProcess.kind` 使用的持久化名称。
  String get storageName {
    return switch (this) {
      BookContentProcessKind.userHighlight => 'user_highlight',
      BookContentProcessKind.userUnderline => 'user_underline',
    };
  }

  /// 从不可信持久化名称恢复已支持的用户标注类型。
  static BookContentProcessKind? fromStorageName(String value) {
    return switch (value) {
      'user_highlight' => BookContentProcessKind.userHighlight,
      'user_underline' => BookContentProcessKind.userUnderline,
      _ => null,
    };
  }
}

/// 保存选区在章节正文中的稳定文本锚点，对应 Android `TextProcessAnchor`。
final class TextProcessAnchor {
  /// 创建包含字符位置、原文和前后文的选区锚点。
  const TextProcessAnchor({
    required this.chapterIndex,
    required this.chapterPosition,
    required this.selectedText,
    required this.contextBefore,
    required this.contextAfter,
    required this.normalizedTextHash,
  });

  /// 选区所属的从零开始章节索引。
  final int chapterIndex;

  /// 创建标注时选区在处理后正文中的起点。
  final int chapterPosition;

  /// 创建标注时保存的完整选区正文。
  final String selectedText;

  /// 选区之前最多四十个字符，用于正文轻微变化后的辅助定位。
  final String contextBefore;

  /// 选区之后最多四十个字符，用于正文轻微变化后的辅助定位。
  final String contextAfter;

  /// 规范化选区正文的摘要，用于后续同步和冲突判断。
  final String normalizedTextHash;
}

/// 保存用户标注的跨平台样式，对应 Android `TextProcessStyle` 的首批子集。
final class TextProcessStyle {
  /// 创建背景高亮或下划线样式。
  const TextProcessStyle({
    this.backgroundColorValue,
    this.underlineColorValue,
    this.underlineWidth = 1,
  });

  /// ARGB 背景色；为空表示不绘制背景高亮。
  final int? backgroundColorValue;

  /// ARGB 下划线颜色；为空表示不绘制标注下划线。
  final int? underlineColorValue;

  /// 下划线逻辑宽度，首批由 Flutter 文本装饰近似消费。
  final double underlineWidth;
}

/// 表示一条可启停、可删除的用户正文标注，对应 Android `BookContentProcess`。
final class BookContentProcess {
  /// 创建不可变正文标注记录。
  const BookContentProcess({
    required this.id,
    required this.bookUrl,
    required this.chapterIndex,
    required this.kind,
    required this.anchor,
    required this.style,
    required this.enabled,
    required this.sortOrder,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 正常参与显示的记录状态。
  static const int activeStatus = 1;

  /// 软删除记录状态。
  static const int deletedStatus = 3;

  /// 跨设备和数据库稳定的标注主键。
  final String id;

  /// 标注所属书籍的稳定 URL。
  final String bookUrl;

  /// 标注所属章节索引；首批用户标注必须指定章节。
  final int chapterIndex;

  /// 用户高亮或下划线类型。
  final BookContentProcessKind kind;

  /// 用于正文变化后重新定位的选区锚点。
  final TextProcessAnchor anchor;

  /// 当前标注绘制样式。
  final TextProcessStyle style;

  /// 用户是否启用该标注。
  final bool enabled;

  /// 同一本书内的稳定创建顺序。
  final int sortOrder;

  /// Android 兼容状态，删除使用软删除而不立即抹除记录。
  final int status;

  /// 创建时间，Unix Epoch 毫秒。
  final int createdAt;

  /// 最近更新时间，Unix Epoch 毫秒。
  final int updatedAt;

  /// 当前记录是否应参与正文绘制。
  bool get isActive => enabled && status == activeStatus;

  /// 在当前处理后正文中解析最接近原字符位置的稳定选区。
  ReaderTextRange? resolveRange(String content) {
    if (!isActive || content.isEmpty || anchor.selectedText.trim().isEmpty) {
      return null;
    }
    /// 创建标注时的原始选区起点，限制到当前正文范围内。
    final int approximatePosition = anchor.chapterPosition
        .clamp(0, content.length)
        .toInt();
    /// 原始选区正文的精确匹配位置。
    final int exactStart = _findBestAnchoredOccurrence(
      content,
      anchor.selectedText,
      approximatePosition,
      anchor.contextBefore,
      anchor.contextAfter,
    );
    if (exactStart >= 0) {
      return ReaderTextRange(
        start: exactStart,
        end: exactStart + anchor.selectedText.length,
      );
    }
    /// 去除普通和全角空白后的正文及其原始字符位置映射。
    final _NormalizedReaderText normalizedContent =
        _normalizeReaderText(content);
    /// 去除普通和全角空白后的选区正文。
    final String normalizedSelection =
        _normalizeReaderText(anchor.selectedText).text;
    if (normalizedSelection.isEmpty) {
      return null;
    }
    /// 规范化文本中的首个候选位置。
    int match = normalizedContent.text.indexOf(normalizedSelection);
    if (match < 0) {
      return null;
    }
    /// 当前最接近旧字符位置的原文起点。
    int closestStart = normalizedContent.sourceIndices[match];
    /// 当前最接近旧字符位置的原文终点。
    int closestEnd = normalizedContent
            .sourceIndices[match + normalizedSelection.length - 1] +
        1;
    /// 当前候选与旧字符位置的绝对距离。
    int closestDistance = (closestStart - approximatePosition).abs();
    while (match >= 0) {
      /// 当前规范化候选对应的原文起点。
      final int sourceStart = normalizedContent.sourceIndices[match];
      /// 当前候选与旧字符位置的距离。
      final int distance = (sourceStart - approximatePosition).abs();
      if (distance < closestDistance) {
        closestStart = sourceStart;
        closestEnd = normalizedContent
                .sourceIndices[match + normalizedSelection.length - 1] +
            1;
        closestDistance = distance;
      }
      match = normalizedContent.text.indexOf(normalizedSelection, match + 1);
    }
    return ReaderTextRange(start: closestStart, end: closestEnd);
  }
}

/// 表示章节正文中左闭右开的稳定字符区间。
final class ReaderTextRange {
  /// 创建已经按正文字符位置收窄的区间。
  const ReaderTextRange({required this.start, required this.end});

  /// 区间首字符位置。
  final int start;

  /// 区间结束位置，不包含该位置字符。
  final int end;

  /// 区间是否包含至少一个字符。
  bool get isNotEmpty => end > start;
}

/// 表示由 Flutter 选择手势解析出的稳定章节选区。
final class ReaderTextSelection {
  /// 创建带原文和稳定字符范围的用户选区。
  const ReaderTextSelection({
    required this.start,
    required this.end,
    required this.text,
  });

  /// 选区在处理后完整正文中的起点。
  final int start;

  /// 选区在处理后完整正文中的终点，不包含该位置字符。
  final int end;

  /// 从完整正文按稳定范围截取的真实文本，不包含显示缩进。
  final String text;
}

/// 保存去除空白后的文本以及每个字符对应的原文位置。
final class _NormalizedReaderText {
  /// 创建规范化正文映射。
  const _NormalizedReaderText({required this.text, required this.sourceIndices});

  /// 去除普通与全角空白后的文本。
  final String text;

  /// 规范化文本每个字符在原文中的位置。
  final List<int> sourceIndices;
}

/// 去除选区匹配不关心的空白，并保留规范化字符到原文的映射。
_NormalizedReaderText _normalizeReaderText(String source) {
  /// 规范化文本缓冲区。
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
  return _NormalizedReaderText(
    text: output.toString(),
    sourceIndices: List<int>.unmodifiable(sourceIndices),
  );
}

/// 在可能重复的正文中优先按前后文、其次按旧字符位置选择精确文本候选。
int _findBestAnchoredOccurrence(
  String content,
  String selectedText,
  int approximatePosition,
  String contextBefore,
  String contextAfter,
) {
  /// 首个精确候选位置。
  int match = content.indexOf(selectedText);
  if (match < 0) {
    return -1;
  }
  /// 当前最接近旧字符位置的候选。
  int closest = match;
  /// 当前候选与旧字符位置的最短距离。
  int closestDistance = (match - approximatePosition).abs();
  /// 当前候选与保存前后文的最大匹配字符数。
  int bestContextScore = _contextMatchScore(
    content,
    match,
    selectedText.length,
    contextBefore,
    contextAfter,
  );
  while (match >= 0) {
    /// 当前候选与旧字符位置的距离。
    final int distance = (match - approximatePosition).abs();
    /// 当前候选与保存前后文的匹配字符数。
    final int contextScore = _contextMatchScore(
      content,
      match,
      selectedText.length,
      contextBefore,
      contextAfter,
    );
    if (contextScore > bestContextScore ||
        (contextScore == bestContextScore && distance < closestDistance)) {
      closest = match;
      closestDistance = distance;
      bestContextScore = contextScore;
    }
    match = content.indexOf(selectedText, match + 1);
  }
  return closest;
}

/// 计算一个选区候选与保存前后文的共同后缀和共同前缀长度。
int _contextMatchScore(
  String content,
  int selectionStart,
  int selectionLength,
  String contextBefore,
  String contextAfter,
) {
  /// 候选之前可参与比较的正文起点。
  final int beforeStart = (selectionStart - contextBefore.length)
      .clamp(0, selectionStart)
      .toInt();
  /// 候选之前的实际正文。
  final String actualBefore = content.substring(beforeStart, selectionStart);
  /// 候选之后的字符起点。
  final int afterStart = selectionStart + selectionLength;
  /// 候选之后可参与比较的正文终点。
  final int afterEnd = (afterStart + contextAfter.length)
      .clamp(afterStart, content.length)
      .toInt();
  /// 候选之后的实际正文。
  final String actualAfter = content.substring(afterStart, afterEnd);
  /// 前文从选区边界向外比较得到的共同后缀长度。
  int beforeScore = 0;
  while (beforeScore < actualBefore.length &&
      beforeScore < contextBefore.length &&
      actualBefore[actualBefore.length - beforeScore - 1] ==
          contextBefore[contextBefore.length - beforeScore - 1]) {
    beforeScore += 1;
  }
  /// 后文从选区边界向外比较得到的共同前缀长度。
  int afterScore = 0;
  while (afterScore < actualAfter.length &&
      afterScore < contextAfter.length &&
      actualAfter[afterScore] == contextAfter[afterScore]) {
    afterScore += 1;
  }
  return beforeScore + afterScore;
}
