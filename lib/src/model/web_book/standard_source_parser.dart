import 'dart:isolate';

import 'package:html/parser.dart' as html_parser;

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../analyze_rule/source_rules.dart';
import '../analyze_rule/standard_rule_engine.dart';

/// 详情页解析结果；由后续 UseCase 决定是否写回书架。
final class ParsedBookInfo {
  /// 创建不可变详情结果。
  const ParsedBookInfo({
    required this.name,
    required this.author,
    this.intro,
    this.kind,
    this.coverUrl,
    this.tocUrl,
    this.latestChapterTitle,
    this.wordCount,
  });

  /// 书名。
  final String name;

  /// 作者。
  final String author;

  /// 简介。
  final String? intro;

  /// 分类。
  final String? kind;

  /// 绝对封面 URL。
  final String? coverUrl;

  /// 绝对目录 URL。
  final String? tocUrl;

  /// 最新章节标题。
  final String? latestChapterTitle;

  /// 字数文本。
  final String? wordCount;
}

/// 单页目录解析结果，保留下一页目录地址供编排层继续请求。
final class ParsedTocPage {
  /// 创建不可变目录页结果。
  ParsedTocPage({
    required List<BookChapter> chapters,
    required List<Uri> nextPageUris,
    required this.reverse,
  })
    : chapters = List<BookChapter>.unmodifiable(chapters),
      nextPageUris = List<Uri>.unmodifiable(nextPageUris);

  /// 当前页章节。
  final List<BookChapter> chapters;

  /// 下一页目录绝对地址。
  final List<Uri> nextPageUris;

  /// 章节列表规则是否带 Android `-` 反序前缀。
  final bool reverse;
}

/// 单页正文解析结果，保留副正文与下一页地址。
final class ParsedContentPage {
  /// 创建不可变正文页结果。
  ParsedContentPage({
    required this.content,
    required List<Uri> nextPageUris,
    this.title,
    this.subContent,
  }) : nextPageUris = List<Uri>.unmodifiable(nextPageUris);

  /// 清理后的正文文本。
  final String content;

  /// 可覆盖章节名称的标题。
  final String? title;

  /// 歌词等副正文。
  final String? subContent;

  /// 下一页正文绝对地址。
  final List<Uri> nextPageUris;
}

/// 在后台 isolate 执行四段普通规则解析。
final class StandardBookSourceParser {
  /// 创建普通书源解析入口。
  const StandardBookSourceParser();

  /// 解析搜索列表；合法空列表与规则异常保持不同结果。
  Future<List<SearchBook>> parseSearch({
    required BookSource source,
    required String body,
    required Uri finalUri,
    required int receivedAt,
  }) {
    return Isolate.run<List<SearchBook>>(
      () => _parseSearchSync(source, body, finalUri, receivedAt),
    );
  }

  /// 解析书籍详情。
  Future<ParsedBookInfo> parseBookInfo({
    required BookSource source,
    required Book book,
    required String body,
    required Uri finalUri,
  }) {
    return Isolate.run<ParsedBookInfo>(
      () => _parseBookInfoSync(source, book, body, finalUri),
    );
  }

  /// 解析单页目录。
  Future<ParsedTocPage> parseTocPage({
    required BookSource source,
    required Book book,
    required String body,
    required Uri finalUri,
    required int startIndex,
  }) {
    return Isolate.run<ParsedTocPage>(
      () => _parseTocSync(source, book, body, finalUri, startIndex),
    );
  }

  /// 解析单页正文。
  Future<ParsedContentPage> parseContentPage({
    required BookSource source,
    required BookChapter chapter,
    required String body,
    required Uri finalUri,
  }) {
    return Isolate.run<ParsedContentPage>(
      () => _parseContentSync(source, chapter, body, finalUri),
    );
  }

  /// 同步解析搜索列表；只在工作 isolate 内调用。
  static List<SearchBook> _parseSearchSync(
    BookSource source,
    String body,
    Uri finalUri,
    int receivedAt,
  ) {
    /// 强类型搜索规则。
    final SearchSourceRule rule = const BookSourceRuleDecoder().decodeSearch(source);
    /// 普通规则引擎。
    const StandardRuleEngine engine = StandardRuleEngine();
    /// 是否反转最终列表。
    final bool reverse = rule.bookList?.startsWith('-') ?? false;
    /// 列表节点。
    final List<StandardRuleNode> nodes = engine.elements(rule.bookList, body).values;
    /// 按详情 URL 去重的结果。
    final Map<String, SearchBook> unique = <String, SearchBook>{};
    for (final StandardRuleNode node in nodes) {
      /// 书名。
      final String name = _cleanName(engine.string(rule.name, node.value));
      if (name.isEmpty) {
        continue;
      }
      /// 作者。
      final String author = _cleanAuthor(engine.string(rule.author, node.value));
      /// 详情地址原始值。
      final String rawBookUrl = engine.string(rule.bookUrl, node.value).trim();
      /// 详情绝对地址；Android 未取到地址时会退回当前页。
      final String bookUrl = _absoluteOrFallback(finalUri, rawBookUrl).toString();
      /// 封面原始地址。
      final String rawCoverUrl = engine.string(rule.coverUrl, node.value).trim();
      /// 分类列表。
      final List<String> kinds = engine.strings(rule.kind, node.value).values;
      unique.putIfAbsent(
        bookUrl,
        () => SearchBook(
          bookUrl: bookUrl,
          origin: source.bookSourceUrl,
          originName: source.bookSourceName,
          name: name,
          author: author,
          type: source.bookSourceType,
          kind: _nullable(kinds.join(','), maxLength: 1000),
          coverUrl: rawCoverUrl.isEmpty ? null : finalUri.resolve(rawCoverUrl).toString(),
          intro: _nullable(
            _plainText(engine.string(rule.intro, node.value)),
            maxLength: 5000,
          ),
          wordCount: _nullable(engine.string(rule.wordCount, node.value)),
          latestChapterTitle: _nullable(engine.string(rule.lastChapter, node.value)),
          time: receivedAt,
          originOrder: source.customOrder,
        ),
      );
    }
    /// 可变结果用于反转。
    final List<SearchBook> result = unique.values.toList(growable: false);
    return reverse ? result.reversed.toList(growable: false) : result;
  }

  /// 同步解析详情；只在工作 isolate 内调用。
  static ParsedBookInfo _parseBookInfoSync(
    BookSource source,
    Book book,
    String body,
    Uri finalUri,
  ) {
    /// 强类型详情规则。
    final BookInfoSourceRule rule = const BookSourceRuleDecoder().decodeBookInfo(source);
    /// 普通规则引擎。
    const StandardRuleEngine engine = StandardRuleEngine();
    /// `init` 规则后的详情上下文。
    final Object? context = rule.init == null || rule.init?.trim().isEmpty == true
        ? body
        : engine.elements(rule.init, body).firstOrNull?.value ?? body;
    /// 规则解析书名。
    final String parsedName = _cleanName(engine.string(rule.name, context));
    /// 规则解析作者。
    final String parsedAuthor = _cleanAuthor(engine.string(rule.author, context));
    /// 封面相对地址。
    final String cover = engine.string(rule.coverUrl, context).trim();
    /// 目录相对地址。
    final String toc = engine.string(rule.tocUrl, context).trim();
    /// Android 以 `canReName` 规则是否非空作为覆盖开关。
    final bool canRename = rule.canReName?.trim().isNotEmpty == true;
    return ParsedBookInfo(
      name: parsedName.isNotEmpty && (canRename || book.name.isEmpty) ? parsedName : book.name,
      author: parsedAuthor.isNotEmpty && (canRename || book.author.isEmpty)
          ? parsedAuthor
          : book.author,
      intro: _nullable(_plainText(engine.string(rule.intro, context)), maxLength: 5000),
      kind: _nullable(engine.strings(rule.kind, context).values.join(','), maxLength: 1000),
      coverUrl: cover.isEmpty ? book.coverUrl : finalUri.resolve(cover).toString(),
      tocUrl: toc.isEmpty ? book.bookUrl : finalUri.resolve(toc).toString(),
      latestChapterTitle: _nullable(engine.string(rule.lastChapter, context)),
      wordCount: _nullable(engine.string(rule.wordCount, context)),
    );
  }

  /// 同步解析目录；只在工作 isolate 内调用。
  static ParsedTocPage _parseTocSync(
    BookSource source,
    Book book,
    String body,
    Uri finalUri,
    int startIndex,
  ) {
    /// 强类型目录规则。
    final TocSourceRule rule = const BookSourceRuleDecoder().decodeToc(source);
    _rejectNonEmptyJavaScript(rule.preUpdateJs, '目录 preUpdateJs');
    _rejectNonEmptyJavaScript(rule.formatJs, '目录 formatJs');
    /// 普通规则引擎。
    const StandardRuleEngine engine = StandardRuleEngine();
    /// 章节节点。
    final List<StandardRuleNode> nodes = engine.elements(rule.chapterList, body).values;
    /// 当前页章节。
    final List<BookChapter> chapters = <BookChapter>[];
    for (int offset = 0; offset < nodes.length; offset += 1) {
      /// 当前章节上下文。
      final Object? context = nodes[offset].value;
      /// 标题。
      final String title = engine.string(rule.chapterName, context).trim();
      if (title.isEmpty) {
        continue;
      }
      /// 是否卷标题。
      final bool isVolume = _isTrue(engine.string(rule.isVolume, context));
      /// 章节原始 URL。
      final String rawUrl = engine.string(rule.chapterUrl, context).trim();
      /// Android 对空 URL 的兼容回退。
      final String chapterUrl = rawUrl.isEmpty
          ? (isVolume ? '$title${startIndex + offset}' : finalUri.toString())
          : finalUri.resolve(rawUrl).toString();
      chapters.add(
        BookChapter(
          url: chapterUrl,
          title: title,
          bookUrl: book.bookUrl,
          index: startIndex + chapters.length,
          isVolume: isVolume,
          baseUrl: finalUri.toString(),
          isVip: _isTrue(engine.string(rule.isVip, context)),
          isPay: _isTrue(engine.string(rule.isPay, context)),
          tag: _nullable(engine.string(rule.updateTime, context)),
        ),
      );
    }
    /// 下一页目录地址。
    final List<Uri> nextUris = _absoluteUris(
      engine.strings(rule.nextTocUrl, body).values,
      finalUri,
    );
    return ParsedTocPage(
      chapters: chapters,
      nextPageUris: nextUris,
      reverse: rule.chapterList?.startsWith('-') ?? false,
    );
  }

  /// 同步解析正文；只在工作 isolate 内调用。
  static ParsedContentPage _parseContentSync(
    BookSource source,
    BookChapter chapter,
    String body,
    Uri finalUri,
  ) {
    /// 强类型正文规则。
    final ContentSourceRule rule = const BookSourceRuleDecoder().decodeContent(source);
    _rejectNonEmptyJavaScript(rule.webJs, '正文 webJs');
    _rejectNonEmptyJavaScript(rule.sourceRegex, '正文 sourceRegex');
    _rejectNonEmptyJavaScript(rule.imageDecode, '正文 imageDecode');
    _rejectNonEmptyJavaScript(rule.payAction, '正文 payAction');
    /// 普通规则引擎。
    const StandardRuleEngine engine = StandardRuleEngine();
    /// 未格式化正文。
    String content = engine.string(rule.content, body);
    if (rule.replaceRegex?.trim().isNotEmpty == true) {
      content = engine.string(rule.replaceRegex, content);
    }
    /// 格式化后的正文。
    final String formatted = _formatContent(content);
    if (!chapter.isVolume && formatted.trim().isEmpty) {
      throw const StandardRuleException('正文规则匹配成功但内容为空');
    }
    return ParsedContentPage(
      content: formatted,
      title: _nullable(engine.string(rule.title, body)),
      subContent: _nullable(engine.string(rule.subContent, body)),
      nextPageUris: _absoluteUris(
        engine.strings(rule.nextContentUrl, body).values,
        finalUri,
      ),
    );
  }

  /// 将相对 URL 列表转成去重绝对地址。
  static List<Uri> _absoluteUris(List<String> values, Uri baseUri) {
    /// 按文本去重的地址。
    final Map<String, Uri> unique = <String, Uri>{};
    for (final String value in values) {
      if (value.trim().isEmpty) {
        continue;
      }
      /// 绝对地址。
      final Uri uri = baseUri.resolve(value.trim());
      unique[uri.toString()] = uri;
    }
    return unique.values.toList(growable: false);
  }

  /// 将 URL 转为绝对地址，空值回退到最终响应地址。
  static Uri _absoluteOrFallback(Uri baseUri, String value) {
    return value.isEmpty ? baseUri : baseUri.resolve(value);
  }

  /// 清理常见书名标签。
  static String _cleanName(String value) {
    return value.replaceFirst(RegExp(r'^\s*书名\s*[:：]\s*'), '').trim();
  }

  /// 清理常见作者标签。
  static String _cleanAuthor(String value) {
    return value.replaceFirst(RegExp(r'^\s*作者\s*[:：]\s*'), '').trim();
  }

  /// 将 HTML 简介转成纯文本。
  static String _plainText(String value) {
    return html_parser.parseFragment(value).text?.trim() ?? '';
  }

  /// 将 HTML 正文转为保留段落换行的文本。
  static String _formatContent(String value) {
    /// 用换行替代常见块级结束与换行标签。
    final String withBreaks = value
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(?:p|div|li|h[1-6])>', caseSensitive: false), '\n');
    /// HTML 解码后的文本。
    final String text = html_parser.parseFragment(withBreaks).text ?? '';
    return text
        .split(RegExp(r'\r?\n'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .join('\n');
  }

  /// 将空文本转为 `null`，并限制 Android 对齐字段长度。
  static String? _nullable(String value, {int? maxLength}) {
    /// 去除首尾空白后的值。
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (maxLength != null && trimmed.length > maxLength) {
      return trimmed.substring(0, maxLength);
    }
    return trimmed;
  }

  /// 兼容 Android `isTrue` 的常用布尔文本。
  static bool _isTrue(String value) {
    /// 小写布尔文本。
    final String normalized = value.trim().toLowerCase();
    if (normalized.isEmpty || normalized == 'null') {
      return false;
    }
    return normalized != 'false' &&
        normalized != 'no' &&
        normalized != 'not' &&
        normalized != '0' &&
        normalized != '0.0';
  }

  /// M3 拒绝非空 JavaScript 专属字段。
  static void _rejectNonEmptyJavaScript(String? value, String field) {
    if (value?.trim().isNotEmpty == true) {
      throw StandardRuleException('$field 需要 M4 JavaScript 支持');
    }
  }
}
