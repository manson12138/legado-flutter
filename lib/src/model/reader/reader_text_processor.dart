import 'dart:async';
import 'dart:isolate';

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/reader_content.dart';
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
    required bool fromCache,
  }) async {
    /// 接收后台处理结果和 isolate 错误的端口。
    final ReceivePort resultPort = ReceivePort();
    /// 传给 isolate 的可发送请求数据。
    final Map<String, Object?> request = <String, Object?>{
      'sendPort': resultPort.sendPort,
      'bookName': book.name,
      'chapterUrl': chapter.url,
      'chapterTitle': displayTitle,
      'rawContent': rawContent,
      'useReplaceRules': useReplaceRules,
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
      if (textValue is! String || countValue is! int || blocksValue is! List<Object?>) {
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
        if (index is! int || blockText is! String || start is! int || end is! int) {
          throw const ReaderTextProcessException('正文分块字段格式无效');
        }
        blocks.add(
          ReaderContentBlock(
            id: '${chapter.url}#$index',
            text: blockText,
            startOffset: start,
            endOffset: end,
          ),
        );
      }
      return ReaderChapterContent(
        chapterUrl: chapter.url,
        title: displayTitle,
        text: textValue,
        blocks: blocks,
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
    /// 统一换行、空白和不换行空格后的正文。
    String text = rawContent
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\u00A0', ' ')
        .trim();
    text = _removeRepeatedTitle(text, bookName, chapterTitle);
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
    text = _normalizeParagraphs(text);
    if (text.isEmpty) {
      throw const FormatException('正文处理完成后为空，请检查书源或替换规则');
    }
    sendPortValue.send(<String, Object?>{
      'text': text,
      'effectiveRuleCount': effectiveRuleCount,
      'blocks': _splitBlocks(text),
    });
  } on FormatException catch (error) {
    sendPortValue.send(<String, Object?>{'error': error.message});
  } on Object {
    sendPortValue.send(<String, Object?>{'error': '正文替换规则执行失败'});
  }
}

/// 去除正文首部与书名或章节标题重复的独立行。
String _removeRepeatedTitle(String text, String bookName, String chapterTitle) {
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

/// 将正文按段落聚合成不超过约 1200 字符的惰性列表块。
List<Map<String, Object?>> _splitBlocks(String text) {
  /// 最终分块。
  final List<Map<String, Object?>> blocks = <Map<String, Object?>>[];
  /// 当前块缓冲区。
  final StringBuffer buffer = StringBuffer();
  /// 当前块起始字符位置。
  int blockStart = 0;
  /// 当前扫描字符位置。
  int cursor = 0;
  for (final String paragraph in text.split('\n')) {
    /// 加入当前段落所需字符数，非首段额外包含一个换行。
    final int requiredLength = paragraph.length + (buffer.isEmpty ? 0 : 1);
    if (buffer.isNotEmpty && buffer.length + requiredLength > 1200) {
      /// 已完成的块文本。
      final String blockText = buffer.toString();
      blocks.add(<String, Object?>{
        'index': blocks.length,
        'text': blockText,
        'start': blockStart,
        'end': blockStart + blockText.length,
      });
      blockStart = cursor;
      buffer.clear();
    }
    if (buffer.isNotEmpty) {
      buffer.write('\n');
      cursor += 1;
    }
    buffer.write(paragraph);
    cursor += paragraph.length;
  }
  if (buffer.isNotEmpty) {
    /// 最后一个正文块。
    final String blockText = buffer.toString();
    blocks.add(<String, Object?>{
      'index': blocks.length,
      'text': blockText,
      'start': blockStart,
      'end': blockStart + blockText.length,
    });
  }
  return blocks;
}
