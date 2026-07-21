import 'dart:async';
import 'dart:isolate';

import 'package:flutter_open_chinese_convert/flutter_open_chinese_convert.dart';

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/model/reader_content_markup.dart';
import '../../domain/model/replace_rule.dart';

/// 正文净化、替换或分块失败时抛出的明确错误。
final class ReaderTextProcessException implements Exception {
  /// 创建不包含用户正文的处理错误。
  const ReaderTextProcessException(this.message);

  /// 可安全展示的错误摘要。
  final String message;

  @override
  String toString() => 'ReaderTextProcessException($message)';
}

/// 在独立 isolate 完成正文净化、替换和分块，避免大章节阻塞 UI isolate。
final class ReaderTextProcessor {
  /// 创建无状态正文处理器。
  const ReaderTextProcessor();

  /// 处理一章原始正文，并在规则异常或超时时结束专用 isolate。
  Future<ReaderChapterContent> process({
    required Book book,
    required BookChapter chapter,
    required String displayTitle,
    required String rawContent,
    required List<ReplaceRule> replaceRules,
    required bool useReplaceRules,
    required ReaderChineseConversionMode chineseConversionMode,
    required bool reSegmentContent,
    required bool fromCache,
  }) async {
    /// 按设置转换且保持图片资源标记原样的正文。
    final String convertedContent = await _convertChineseText(
      rawContent,
      chineseConversionMode,
    );
    /// 与正文使用同一模式转换后的章节显示标题。
    final String convertedTitle = await _convertChineseText(
      displayTitle,
      chineseConversionMode,
    );
    /// 与正文使用同一模式转换后的书名，用于准确识别重复标题。
    final String convertedBookName = await _convertChineseText(
      book.name,
      chineseConversionMode,
    );
    /// 接收后台处理结果和 isolate 错误的端口。
    final ReceivePort resultPort = ReceivePort();
    /// 传给 isolate 的可发送请求数据。
    final Map<String, Object?> request = <String, Object?>{
      'sendPort': resultPort.sendPort,
      'bookName': convertedBookName,
      'chapterUrl': chapter.url,
      'chapterTitle': convertedTitle,
      'rawContent': convertedContent,
      'useReplaceRules': useReplaceRules,
      'reSegment': reSegmentContent || (book.readConfig?.reSegment ?? false),
      'rules': replaceRules.map(_ruleToMap).toList(growable: false),
    };
    /// 当前专用处理 isolate。
    final Isolate isolate = await Isolate.spawn<Map<String, Object?>>(
      _readerTextWorker,
      request,
      onError: resultPort.sendPort,
      errorsAreFatal: true,
    );
    try {
      /// 首个处理成功或后台错误事件。
      final Object? message = await resultPort.first.timeout(
        _processingTimeout(replaceRules),
      );
      if (message is! Map<Object?, Object?>) {
        throw const ReaderTextProcessException('正文后台处理返回了无效结果');
      }
      /// 后台错误摘要。
      final Object? errorMessage = message['error'];
      if (errorMessage is String && errorMessage.isNotEmpty) {
        throw ReaderTextProcessException(errorMessage);
      }
      /// 处理后完整正文。
      final Object? textValue = message['text'];
      /// 实际生效规则数量。
      final Object? countValue = message['effectiveRuleCount'];
      /// 分块原始数组。
      final Object? blocksValue = message['blocks'];
      /// 图片资源原始数组。
      final Object? imagesValue = message['images'];
      if (textValue is! String ||
          countValue is! int ||
          blocksValue is! List<Object?> ||
          imagesValue is! List<Object?>) {
        throw const ReaderTextProcessException('正文后台处理结果字段不完整');
      }
      /// 已收窄的正文块。
      final List<ReaderContentBlock> blocks = <ReaderContentBlock>[];
      for (final Object? blockValue in blocksValue) {
        if (blockValue is! Map<Object?, Object?>) {
          throw const ReaderTextProcessException('正文分块结果格式无效');
        }
        /// 块序号。
        final Object? index = blockValue['index'];
        /// 块正文。
        final Object? blockText = blockValue['text'];
        /// 起始字符位置。
        final Object? start = blockValue['start'];
        /// 结束字符位置。
        final Object? end = blockValue['end'];
        /// 正文块类型名称。
        final Object? kindValue = blockValue['kind'];
        /// 图片资源地址；文本块固定为空字符串。
        final Object? resourceUrlValue = blockValue['resourceUrl'];
        /// 图片替代文本；文本块固定为空字符串。
        final Object? altTextValue = blockValue['altText'];
        /// 图片防盗链来源地址；文本块固定为空字符串。
        final Object? refererValue = blockValue['referer'];
        if (index is! int ||
            blockText is! String ||
            start is! int ||
            end is! int ||
            kindValue is! String ||
            resourceUrlValue is! String ||
            altTextValue is! String ||
            refererValue is! String) {
          throw const ReaderTextProcessException('正文分块字段格式无效');
        }
        /// 已收窄的正文块类型。
        final ReaderContentBlockKind kind = kindValue == ReaderContentBlockKind.image.name
            ? ReaderContentBlockKind.image
            : ReaderContentBlockKind.text;
        blocks.add(
          ReaderContentBlock(
            id: '${chapter.url}#$index',
            text: blockText,
            startOffset: start,
            endOffset: end,
            kind: kind,
            resourceUrl: resourceUrlValue,
            altText: altTextValue,
            resourceReferer: refererValue,
          ),
        );
      }
      /// 已收窄的正文图片列表。
      final List<ReaderContentImage> images = <ReaderContentImage>[];
      for (final Object? imageValue in imagesValue) {
        if (imageValue is! Map<Object?, Object?>) {
          throw const ReaderTextProcessException('正文图片结果格式无效');
        }
        /// 图片顺序索引。
        final Object? index = imageValue['index'];
        /// 图片绝对地址。
        final Object? url = imageValue['url'];
        /// 图片替代文本。
        final Object? altText = imageValue['altText'];
        /// 图片稳定字符位置。
        final Object? characterOffset = imageValue['characterOffset'];
        /// 图片防盗链来源地址。
        final Object? referer = imageValue['referer'];
        if (index is! int ||
            url is! String ||
            altText is! String ||
            characterOffset is! int ||
            referer is! String) {
          throw const ReaderTextProcessException('正文图片字段格式无效');
        }
        images.add(
          ReaderContentImage(
            id: '${chapter.url}#image-$index',
            url: url,
            altText: altText,
            characterOffset: characterOffset,
            referer: referer,
          ),
        );
      }
      return ReaderChapterContent(
        chapterUrl: chapter.url,
        title: convertedTitle,
        text: textValue,
        blocks: blocks,
        images: images,
        effectiveReplaceRuleCount: countValue,
        fromCache: fromCache,
      );
    } on TimeoutException {
      throw const ReaderTextProcessException('正文替换或分块处理超时');
    } finally {
      isolate.kill(priority: Isolate.immediate);
      resultPort.close();
    }
  }

  /// 使用 OpenCC 完成 Android/iOS 共用的简繁转换，并保护正文图片资源标记。
  Future<String> _convertChineseText(
    String input,
    ReaderChineseConversionMode mode,
  ) async {
    if (input.isEmpty || mode == ReaderChineseConversionMode.none) {
      return input;
    }
    /// 转换期间用只含 ASCII 的稳定占位符保护图片 URL 和替代文本。
    final Map<String, String> protectedMarkers = <String, String>{};
    /// 不含资源标记的待转换文本。
    final String protectedInput = input.replaceAllMapped(
      ReaderContentMarkup.imageMarkerPattern,
      (Match match) {
        /// 当前图片标记的稳定占位符。
        final String placeholder = 'LEGADORESOURCE${protectedMarkers.length}TOKEN';
        protectedMarkers[placeholder] = match.group(0) ?? '';
        return placeholder;
      },
    );
    try {
      /// OpenCC 平台实现返回的完整转换文本。
      String converted = switch (mode) {
        ReaderChineseConversionMode.none => protectedInput,
        ReaderChineseConversionMode.traditionalToSimplified =>
          await ChineseConverter.convert(protectedInput, T2S()),
        ReaderChineseConversionMode.simplifiedToTraditional =>
          await ChineseConverter.convert(protectedInput, S2T()),
      };
      for (final MapEntry<String, String> entry in protectedMarkers.entries) {
        converted = converted.replaceAll(entry.key, entry.value);
      }
      return converted;
    } on Object {
      throw const ReaderTextProcessException('简繁转换失败，请关闭转换后重试');
    }
  }

  /// 将替换规则转换为 isolate 可发送数据。
  Map<String, Object?> _ruleToMap(ReplaceRule rule) {
    return <String, Object?>{
      'name': rule.name,
      'pattern': rule.pattern,
      'replacement': rule.replacement,
      'isRegex': rule.isRegex,
      'timeoutMillisecond': rule.timeoutMillisecond,
    };
  }

  /// 依据规则声明的超时生成整个处理任务上限，并限制无界等待。
  Duration _processingTimeout(List<ReplaceRule> rules) {
    /// 所有规则声明超时之和。
    final int declared = rules.fold<int>(0, (int value, ReplaceRule rule) {
      return value + rule.timeoutMillisecond.clamp(100, 3000).toInt();
    });
    /// 至少三秒，最多十二秒，并为净化和分块保留一秒。
    final int milliseconds = (declared + 1000).clamp(3000, 12000).toInt();
    return Duration(milliseconds: milliseconds);
  }
}

/// isolate 顶级入口：任何异常都转换为不包含原始正文的错误摘要。
void _readerTextWorker(Map<String, Object?> request) {
  /// 主 isolate 回传端口。
  final Object? sendPortValue = request['sendPort'];
  if (sendPortValue is! SendPort) {
    return;
  }
  try {
    /// 书名，用于去除章节首部重复标题。
    final String bookName = request['bookName'] is String ? request['bookName'] as String : '';
    /// 章节标题。
    final String chapterTitle = request['chapterTitle'] is String ? request['chapterTitle'] as String : '';
    /// 原始正文。
    final String rawContent = request['rawContent'] is String ? request['rawContent'] as String : '';
    /// 是否应用替换规则。
    final bool useReplaceRules = request['useReplaceRules'] is bool
        ? request['useReplaceRules'] as bool
        : false;
    /// 是否按单书配置重新连接错误断行并切分过长段落。
    final bool reSegment = request['reSegment'] is bool
        ? request['reSegment'] as bool
        : false;
    /// 统一换行、空白和不换行空格后的正文。
    String text = rawContent
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\u00A0', ' ')
        .trim();
    text = _removeRepeatedTitle(text, bookName, chapterTitle);
    if (reSegment) {
      text = _reSegmentContent(text);
    }
    /// 替换规则执行期间受到保护的图片资源标记。
    final _ProtectedReaderMarkers protectedMarkers = _protectReaderMarkers(text);
    text = protectedMarkers.text;
    /// 实际改变正文的规则数量。
    int effectiveRuleCount = 0;
    if (useReplaceRules) {
      /// isolate 收到的规则数组。
      final Object? rulesValue = request['rules'];
      if (rulesValue is List<Object?>) {
        for (final Object? ruleValue in rulesValue) {
          if (ruleValue is! Map<Object?, Object?>) {
            continue;
          }
          /// 规则模式。
          final Object? patternValue = ruleValue['pattern'];
          /// 替换文本。
          final Object? replacementValue = ruleValue['replacement'];
          if (patternValue is! String || patternValue.isEmpty || replacementValue is! String) {
            continue;
          }
          /// 替换前正文，用于统计生效规则。
          final String before = text;
          if (ruleValue['isRegex'] == true) {
            /// Dart 正则对象；语法不兼容时由外层返回明确处理错误。
            final RegExp expression = RegExp(patternValue, multiLine: true);
            text = text.replaceAllMapped(
              expression,
              (Match match) => _expandReplacement(replacementValue, match),
            );
          } else {
            text = text.replaceAll(patternValue, replacementValue);
          }
          if (text != before) {
            effectiveRuleCount += 1;
          }
        }
      }
    }
    text = _restoreReaderMarkers(text, protectedMarkers.markers);
    text = _normalizeParagraphs(text);
    if (text.isEmpty) {
      throw const FormatException('正文处理完成后为空，请检查书源或替换规则');
    }
    /// 把资源标记转换为对象字符、文本块和图片块后的结果。
    final _ReaderContentSplitResult splitResult = _splitContent(text);
    sendPortValue.send(<String, Object?>{
      'text': splitResult.text,
      'effectiveRuleCount': effectiveRuleCount,
      'blocks': splitResult.blocks,
      'images': splitResult.images,
    });
  } on FormatException catch (error) {
    sendPortValue.send(<String, Object?>{'error': error.message});
  } on Object {
    sendPortValue.send(<String, Object?>{'error': '正文替换规则执行失败'});
  }
}

/// 对齐 Android `ContentHelp.reSegment` 的核心行为：连接错误断行并按句末重排长段。
String _reSegmentContent(String text) {
  /// 重排后的段落列表。
  final List<String> paragraphs = <String>[];
  /// 尚未形成完整段落的文本缓冲区。
  final StringBuffer pending = StringBuffer();

  /// 完成当前普通文本缓冲区，并按句末标点拆分过长段落。
  void flushPending() {
    if (pending.isEmpty) {
      return;
    }
    /// 去除段内错误全角或半角空白后的正文。
    final String normalized = pending
        .toString()
        .replaceAll(RegExp(r'[\s\u3000]+'), '')
        .trim();
    pending.clear();
    if (normalized.isEmpty) {
      return;
    }
    /// 逐句匹配表达式，保留结束标点和其后的右引号。
    final RegExp sentencePattern = RegExp(r'.+?[。！？!?…]+[”」』》）)]*|.+$');
    /// 当前重新组合的段落。
    final StringBuffer paragraph = StringBuffer();
    for (final RegExpMatch match in sentencePattern.allMatches(normalized)) {
      /// 当前包含句末标点的完整句子。
      final String sentence = match.group(0) ?? '';
      paragraph.write(sentence);
      if (paragraph.length >= 180 || sentence.endsWith('”')) {
        paragraphs.add(paragraph.toString());
        paragraph.clear();
      }
    }
    if (paragraph.isNotEmpty) {
      paragraphs.add(paragraph.toString());
    }
  }

  for (final String rawLine in text.split('\n')) {
    /// 当前去除外层空白后的原始行。
    final String line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    if (ReaderContentMarkup.tryParseImage(line) != null) {
      flushPending();
      paragraphs.add(line);
      continue;
    }
    pending.write(line);
    if (RegExp(r'[。！？!?…][”」』》）)]?$').hasMatch(line)) {
      flushPending();
    }
  }
  flushPending();
  return paragraphs.join('\n');
}

/// 替换规则执行期间的正文和资源标记映射。
final class _ProtectedReaderMarkers {
  /// 创建资源标记保护结果。
  const _ProtectedReaderMarkers({required this.text, required this.markers});

  /// 已把资源标记替换为稳定占位符的正文。
  final String text;

  /// 占位符到原始资源标记的映射。
  final Map<String, String> markers;
}

/// 用稳定占位符保护图片标记，避免正文替换规则改写 URL 或协议结构。
_ProtectedReaderMarkers _protectReaderMarkers(String text) {
  /// 占位符到原始标记的映射。
  final Map<String, String> markers = <String, String>{};
  /// 已替换全部图片标记的正文。
  final String protectedText = text.replaceAllMapped(
    ReaderContentMarkup.imageMarkerPattern,
    (Match match) {
      /// 当前资源标记占位符。
      final String placeholder = 'LEGADOPROTECTEDIMAGE${markers.length}TOKEN';
      markers[placeholder] = match.group(0) ?? '';
      return placeholder;
    },
  );
  return _ProtectedReaderMarkers(text: protectedText, markers: markers);
}

/// 在替换规则执行结束后恢复受控图片资源标记。
String _restoreReaderMarkers(String text, Map<String, String> markers) {
  /// 逐项恢复后的正文。
  String restored = text;
  for (final MapEntry<String, String> entry in markers.entries) {
    restored = restored.replaceAll(entry.key, entry.value);
  }
  return restored;
}

/// 去除正文首部与书名或章节标题重复的独立行。
String _removeRepeatedTitle(String text, String bookName, String chapterTitle) {
  /// 章节标题去除外层空白后的匹配文本。
  final String normalizedTitle = chapterTitle.trim();
  if (normalizedTitle.isNotEmpty) {
    /// 允许标题原有空白在正文中变成任意数量空白的安全正则片段。
    final String titlePattern = normalizedTitle
        .split(RegExp(r'\s+'))
        .map(RegExp.escape)
        .join(r'\s*');
    /// 书名作为标题前缀出现时使用的安全正则片段。
    final String bookPattern = RegExp.escape(bookName.trim());
    /// 对齐 Android 的章首标题匹配：允许标题前存在书名、空白或 Unicode 标点。
    final RegExp leadingTitlePattern = RegExp(
      bookPattern.isEmpty
          ? '^(?:\\s|\\p{P})*$titlePattern\\s*'
          : '^(?:\\s|\\p{P}|$bookPattern)*$titlePattern\\s*',
      unicode: true,
    );
    /// 章首标题匹配结果。
    final RegExpMatch? leadingMatch = leadingTitlePattern.firstMatch(text);
    if (leadingMatch != null && leadingMatch.start == 0) {
      return text.substring(leadingMatch.end).trim();
    }
  }
  /// 正文行列表。
  final List<String> lines = text.split('\n');
  while (lines.isNotEmpty) {
    /// 首行去除常见标点和空白后的文本。
    final String first = lines.first.trim().replaceAll(RegExp(r'^[\s\p{P}]+', unicode: true), '');
    if (first == chapterTitle.trim() || first == bookName.trim()) {
      lines.removeAt(0);
      continue;
    }
    break;
  }
  return lines.join('\n').trim();
}

/// 将 Android 常见的美元分组和反斜杠分组替换文本展开为实际捕获内容。
String _expandReplacement(String replacement, Match match) {
  /// 展开后的替换文本。
  String result = replacement;
  for (int index = match.groupCount; index >= 1; index -= 1) {
    /// 当前捕获组内容，未参与匹配时按空字符串处理。
    final String value = match.group(index) ?? '';
    result = result.replaceAll('\$$index', value).replaceAll('\\$index', value);
  }
  return result;
}

/// 去除空段并统一段内首尾空白，同时保留段落换行作为字符锚点的一部分。
String _normalizeParagraphs(String text) {
  /// 非空段落。
  final List<String> paragraphs = text
      .split('\n')
      .map((String value) => value.trim())
      .where((String value) => value.isNotEmpty)
      .toList(growable: false);
  return paragraphs.join('\n');
}

/// 正文分块后同时返回稳定纯文本、显示块和图片锚点。
final class _ReaderContentSplitResult {
  /// 创建 isolate 内部正文分块结果。
  const _ReaderContentSplitResult({
    required this.text,
    required this.blocks,
    required this.images,
  });

  /// 图片使用对象替代字符占位后的稳定正文。
  final String text;

  /// 可发送回主 isolate 的文本和图片块。
  final List<Map<String, Object?>> blocks;

  /// 可发送回主 isolate 的图片稳定位置列表。
  final List<Map<String, Object?>> images;
}

/// 将正文按段落聚合文本块，并把图片标记转换为独立资源块。
_ReaderContentSplitResult _splitContent(String text) {
  /// 最终分块。
  final List<Map<String, Object?>> blocks = <Map<String, Object?>>[];
  /// 最终图片稳定位置列表。
  final List<Map<String, Object?>> images = <Map<String, Object?>>[];
  /// 对字符锚点可见的完整正文缓冲区。
  final StringBuffer plainText = StringBuffer();
  /// 当前待聚合文本块缓冲区。
  final StringBuffer textBlock = StringBuffer();
  /// 当前文本块在完整正文中的起始位置。
  int textBlockStart = 0;

  /// 完成当前文本块并清空缓冲区。
  void flushTextBlock() {
    if (textBlock.isEmpty) {
      return;
    }
    /// 已完成的正文块文本。
    final String blockText = textBlock.toString();
    blocks.add(<String, Object?>{
      'index': blocks.length,
      'kind': ReaderContentBlockKind.text.name,
      'text': blockText,
      'resourceUrl': '',
      'altText': '',
      'referer': '',
      'start': textBlockStart,
      'end': textBlockStart + blockText.length,
    });
    textBlock.clear();
  }

  /// 已规范化的正文段落列表。
  final List<String> paragraphs = text.split('\n');
  for (int paragraphIndex = 0; paragraphIndex < paragraphs.length; paragraphIndex += 1) {
    /// 当前段落。
    final String paragraph = paragraphs[paragraphIndex];
    /// 当前段落是否是受控图片标记。
    final ReaderMarkedImage? markedImage = ReaderContentMarkup.tryParseImage(paragraph);
    if (markedImage != null) {
      flushTextBlock();
      if (plainText.isNotEmpty) {
        plainText.write('\n');
      }
      /// 图片在稳定正文中的对象字符位置。
      final int imageOffset = plainText.length;
      plainText.write('\uFFFC');
      blocks.add(<String, Object?>{
        'index': blocks.length,
        'kind': ReaderContentBlockKind.image.name,
        'text': '',
        'resourceUrl': markedImage.uri.toString(),
        'altText': markedImage.altText,
        'referer': markedImage.referer,
        'start': imageOffset,
        'end': imageOffset + 1,
      });
      images.add(<String, Object?>{
        'index': images.length,
        'url': markedImage.uri.toString(),
        'altText': markedImage.altText,
        'characterOffset': imageOffset,
        'referer': markedImage.referer,
      });
      continue;
    }
    /// 当前段落相对已有文本块需要增加的字符数。
    final int separatorLength = plainText.isEmpty ? 0 : 1;
    if (textBlock.isNotEmpty && textBlock.length + 1 + paragraph.length > 1200) {
      flushTextBlock();
    }
    if (separatorLength > 0) {
      plainText.write('\n');
      if (textBlock.isNotEmpty) {
        textBlock.write('\n');
      }
    }
    if (textBlock.isEmpty) {
      textBlockStart = plainText.length;
    }
    plainText.write(paragraph);
    textBlock.write(paragraph);
  }
  flushTextBlock();
  return _ReaderContentSplitResult(
    text: plainText.toString(),
    blocks: blocks,
    images: images,
  );
}
