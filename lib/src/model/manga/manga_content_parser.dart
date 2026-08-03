import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../domain/model/book_chapter.dart';
import '../../domain/model/manga_chapter.dart';
import '../../domain/model/manga_page.dart';
import '../../domain/model/reader_content_markup.dart';

/// 从章节正文中按 Android `BookHelp.flowImages` 语义提取漫画图片。
final class MangaContentParser {
  /// 创建无状态漫画正文解析器。
  const MangaContentParser();

  /// 不可信图片地址允许的最大字符数，避免超长属性进入 URI 解析。
  static const int _maximumImageUrlLength = 16 * 1024;

  /// 图片替代文本允许保留的最大字符数。
  static const int _maximumAltTextLength = 500;

  /// 匹配常见 HTML 图片标签；属性语义交由 HTML 解析器处理。
  static final RegExp _htmlImagePattern = RegExp(
    r'<img\b[^>]*>',
    caseSensitive: false,
    multiLine: true,
  );

  /// 书源常用的图片及懒加载地址属性，顺序与正文安全格式化管线一致。
  static const List<String> _sourceAttributes = <String>[
    'src',
    'data-src',
    'data-original',
    'data-url',
    'data-lazy-src',
  ];

  /// 解析章节正文中的安全标记与常见 `<img>`，返回有序且不可变的章节结果。
  ///
  /// [finalResponseUri] 应传正文最后一次响应地址；缺失时回退到章节绝对 URL。
  /// 相对图片在两者都不可用时会被拒绝，避免错误拼接为本地路径。
  MangaChapter parse({
    required BookChapter chapter,
    required int chapterCount,
    required String content,
    Uri? finalResponseUri,
  }) {
    /// 可用于解析相对图片和填写防盗链的安全 HTTP(S) 基准地址。
    final Uri? baseUri = _resolveBaseUri(
      chapter: chapter,
      finalResponseUri: finalResponseUri,
    );
    /// 同时记录安全标记和 HTML 标签在原正文中的位置，以保持原始顺序。
    final List<_MangaImageCandidate> candidates = <_MangaImageCandidate>[];
    for (final RegExpMatch match in ReaderContentMarkup.imageMarkerPattern.allMatches(content)) {
      /// 当前安全图片标记的完整文本。
      final String marker = match.group(0) ?? '';
      /// 从受控标记恢复的图片元数据。
      final ReaderMarkedImage? markedImage = ReaderContentMarkup.tryParseImage(marker);
      if (markedImage == null) {
        continue;
      }
      candidates.add(
        _MangaImageCandidate(
          sourceOffset: match.start,
          imageUri: markedImage.uri,
          requestUrl: markedImage.requestUrl,
          referer: markedImage.referer,
          altText: _boundedAltText(markedImage.altText),
        ),
      );
    }
    for (final RegExpMatch match in _htmlImagePattern.allMatches(content)) {
      /// 当前 HTML 图片标签的完整文本。
      final String imageTag = match.group(0) ?? '';
      /// 从图片标签中恢复的首个安全图片候选。
      final _MangaImageCandidate? candidate = _parseHtmlImage(
        imageTag: imageTag,
        sourceOffset: match.start,
        baseUri: baseUri,
      );
      if (candidate != null) {
        candidates.add(candidate);
      }
    }
    candidates.sort(
      (_MangaImageCandidate left, _MangaImageCandidate right) =>
          left.sourceOffset.compareTo(right.sourceOffset),
    );

    /// 只移除地址完全相同且相邻的图片，保留后续再次出现的同一资源。
    final List<_MangaImageCandidate> deduplicated = <_MangaImageCandidate>[];
    String? previousImageUrl;
    for (final _MangaImageCandidate candidate in candidates) {
      /// 用未经改写的绝对 URI 文本执行 Android 对齐的相邻去重。
      final String imageUrl = candidate.requestUrl;
      if (imageUrl == previousImageUrl) {
        continue;
      }
      deduplicated.add(candidate);
      previousImageUrl = imageUrl;
    }

    /// 当前章节有效图片总数，写入每个页面供阅读进度展示。
    final int imageCount = deduplicated.length;
    /// 最终不可变领域页面集合。
    final List<MangaPage> pages = <MangaPage>[];
    for (int imageIndex = 0; imageIndex < imageCount; imageIndex += 1) {
      /// 当前有序图片候选。
      final _MangaImageCandidate candidate = deduplicated[imageIndex];
      pages.add(
        MangaPage(
          chapterUrl: chapter.url,
          chapterIndex: chapter.index,
          chapterCount: chapterCount,
          chapterTitle: chapter.title,
          imageIndex: imageIndex,
          imageCount: imageCount,
          imageUri: candidate.imageUri,
          requestUrl: candidate.requestUrl,
          referer: candidate.referer,
          altText: candidate.altText,
        ),
      );
    }
    return MangaChapter(
      chapter: chapter,
      pages: pages,
      state: _contentState(
        chapter: chapter,
        content: content,
        imageCount: imageCount,
      ),
    );
  }

  /// 选择最终响应地址或章节 URL 作为相对资源解析基准。
  static Uri? _resolveBaseUri({
    required BookChapter chapter,
    required Uri? finalResponseUri,
  }) {
    if (finalResponseUri != null && _isSafeHttpUri(finalResponseUri)) {
      return finalResponseUri;
    }
    /// 从不可信章节地址恢复的 URI。
    final Uri? chapterUri = Uri.tryParse(chapter.url);
    if (chapterUri != null && _isSafeHttpUri(chapterUri)) {
      return chapterUri;
    }
    return null;
  }

  /// 从单个 HTML 图片标签中读取常见地址属性和替代文本。
  static _MangaImageCandidate? _parseHtmlImage({
    required String imageTag,
    required int sourceOffset,
    required Uri? baseUri,
  }) {
    /// 只解析已由正则界定的单个标签，不执行脚本或加载外部资源。
    final dom.DocumentFragment fragment = html_parser.parseFragment(imageTag);
    dom.Element? image;
    for (final dom.Node node in fragment.nodes) {
      if (node is dom.Element && node.localName?.toLowerCase() == 'img') {
        image = node;
        break;
      }
    }
    if (image == null) {
      return null;
    }
    /// 首个通过安全协议校验的绝对图片地址。
    Uri? imageUri;
    /// 与当前图片对应并保留请求选项的绝对地址规则。
    String requestUrl = '';
    for (final String attribute in _sourceAttributes) {
      /// 当前图片地址属性值。
      final String source = image.attributes[attribute]?.trim() ?? '';
      /// 当前属性解析和协议校验后的绝对图片地址。
      final Uri? resolved = _resolveImageUri(source: source, baseUri: baseUri);
      if (resolved != null) {
        imageUri = resolved;
        requestUrl = _absoluteRequestUrl(source: source, imageUri: resolved);
        break;
      }
    }
    if (imageUri == null) {
      return null;
    }
    /// 图片替代文本，过长时有界截断。
    final String altText = _boundedAltText(image.attributes['alt']?.trim() ?? '');
    return _MangaImageCandidate(
      sourceOffset: sourceOffset,
      imageUri: imageUri,
      requestUrl: requestUrl,
      referer: baseUri?.toString() ?? '',
      altText: altText,
    );
  }

  /// 将绝对或相对图片地址解析为安全 HTTP(S) URI。
  static Uri? _resolveImageUri({required String source, required Uri? baseUri}) {
    if (source.isEmpty || source.length > _maximumImageUrlLength) {
      return null;
    }
    /// 图片 URL 与其 JSON 请求选项的分隔位置。
    final RegExpMatch? optionStart = RegExp(r'\s*,\s*(?=\{)').firstMatch(source);
    /// 不包含 Header 等请求选项的图片地址正文。
    final String urlText = (optionStart == null
            ? source
            : source.substring(0, optionStart.start))
        .trim();
    /// 图片属性自身可直接表达的绝对或相对 URI。
    final Uri? parsed = Uri.tryParse(urlText);
    if (parsed == null) {
      return null;
    }
    if (parsed.hasScheme) {
      return _isSafeHttpUri(parsed) ? parsed : null;
    }
    if (baseUri == null) {
      return null;
    }
    try {
      /// 使用正文最终响应或章节地址解析的绝对图片 URI。
      final Uri resolved = baseUri.resolveUri(parsed);
      return _isSafeHttpUri(resolved) ? resolved : null;
    } on FormatException {
      return null;
    }
  }

  /// 把图片地址正文替换为绝对 URL，同时原样保留其 JSON 请求选项。
  static String _absoluteRequestUrl({required String source, required Uri imageUri}) {
    /// 图片 URL 与其 JSON 请求选项的分隔位置。
    final RegExpMatch? optionStart = RegExp(r'\s*,\s*(?=\{)').firstMatch(source);
    if (optionStart == null) {
      return imageUri.toString();
    }
    /// 从分隔逗号开始保留的 Android URL 选项。
    final String options = source.substring(optionStart.start).trimLeft();
    return '${imageUri.toString()}$options';
  }

  /// 判断 URI 是否为带远端主机的 HTTP(S) 地址。
  static bool _isSafeHttpUri(Uri uri) {
    return uri.host.isNotEmpty &&
        <String>{'http', 'https'}.contains(uri.scheme.toLowerCase());
  }

  /// 区分可读章节、卷标题、正文为空和正文无图片四种状态。
  static MangaChapterContentState _contentState({
    required BookChapter chapter,
    required String content,
    required int imageCount,
  }) {
    if (imageCount > 0) {
      return MangaChapterContentState.ready;
    }
    if (chapter.isVolume) {
      return MangaChapterContentState.volume;
    }
    if (content.trim().isEmpty) {
      return MangaChapterContentState.emptyContent;
    }
    return MangaChapterContentState.noImages;
  }

  /// 清理并限制不可信替代文本长度，防止异常标签撑大页面状态。
  static String _boundedAltText(String value) {
    /// 去除外层空白后的替代文本。
    final String normalized = value.trim();
    if (normalized.length <= _maximumAltTextLength) {
      return normalized;
    }
    return normalized.substring(0, _maximumAltTextLength);
  }
}

/// 记录图片元数据及其在原正文中的位置，供解析阶段稳定排序。
final class _MangaImageCandidate {
  /// 创建一条已完成 URI 校验的临时图片候选。
  const _MangaImageCandidate({
    required this.sourceOffset,
    required this.imageUri,
    required this.requestUrl,
    required this.referer,
    required this.altText,
  });

  /// 图片标记或标签在原正文中的字符位置。
  final int sourceOffset;

  /// 已解析为绝对 HTTP(S) 地址的图片资源。
  final Uri imageUri;

  /// 已绝对化但仍保留图片请求选项的地址规则。
  final String requestUrl;

  /// 图片请求可使用的安全 Referer。
  final String referer;

  /// 图片加载失败时可展示的有界替代文本。
  final String altText;
}
