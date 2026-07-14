import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/local_book.dart';
import 'local_book_parser.dart';

/// 解析 EPUB 容器、OPF manifest/spine、基础元数据和 XHTML 正文。
final class EpubLocalBookParser implements LocalBookParser {
  /// 创建无状态 EPUB 解析器。
  const EpubLocalBookParser();

  /// EPUB 归档最大条目数，防止异常容器无界占用资源。
  static const int maxArchiveEntries = 10000;

  /// EPUB 解压后所有声明条目的最大总大小。
  static const int maxExpandedBytes = 1024 * 1024 * 1024;

  /// 当前解析器只负责 EPUB。
  @override
  LocalBookFormat get format => LocalBookFormat.epub;

  /// 在后台 isolate 校验容器并按 OPF spine 建立目录。
  @override
  Future<ParsedLocalBook> parse({
    required String filePath,
    required String bookUrl,
    required LocalBookFileReference reference,
    required String referenceJson,
  }) async {
    /// 后台 EPUB 容器解析结果。
    final _EpubPayload payload = await Isolate.run<_EpubPayload>(
      () => _parseEpubFile(filePath),
    );
    /// 数据库章节列表。
    final List<BookChapter> chapters = payload.chapters.indexed.map(((int, _EpubChapter) entry) {
      /// 当前 spine 顺序。
      final int index = entry.$1;
      /// 当前 EPUB 章节事实。
      final _EpubChapter chapter = entry.$2;
      return BookChapter(
        url: 'epub:${chapter.entryPath}',
        title: chapter.title,
        bookUrl: bookUrl,
        index: index,
        baseUrl: path.posix.dirname(chapter.entryPath),
        variable: jsonEncode(<String, Object>{'entryPath': chapter.entryPath}),
      );
    }).toList(growable: false);
    /// 当前导入时间。
    final int now = DateTime.now().millisecondsSinceEpoch;
    return ParsedLocalBook(
      book: Book(
        bookUrl: bookUrl,
        origin: 'loc_book',
        originName: reference.displayName,
        name: payload.title.trim().isEmpty
            ? path.basenameWithoutExtension(reference.displayName)
            : payload.title.trim(),
        author: payload.author.trim().isEmpty ? '未知' : payload.author.trim(),
        type: 264,
        latestChapterTitle: chapters.last.title,
        latestChapterTime: now,
        lastCheckTime: now,
        totalChapterNum: chapters.length,
        canUpdate: false,
        variable: referenceJson,
      ),
      chapters: chapters,
    );
  }

  /// 在后台 isolate 只展开目录指定的 XHTML 条目并转换为安全纯文本。
  @override
  Future<String> loadChapter({
    required String filePath,
    required Book book,
    required BookChapter chapter,
  }) async {
    /// 从章节变量恢复的 EPUB 条目路径。
    final String entryPath = _entryPathFromChapter(chapter);
    return Isolate.run<String>(() {
      /// 当前 EPUB 完整归档。
      final Archive archive = ZipDecoder().decodeBytes(File(filePath).readAsBytesSync(), verify: true);
      _validateArchive(archive);
      /// 目录指向的 XHTML 文件。
      final ArchiveFile? entry = archive.find(entryPath);
      if (entry == null || !entry.isFile) {
        throw const LocalBookException('EPUB 章节资源已经缺失，请重新导入');
      }
      /// 原始 XHTML 文本。
      final String html = utf8.decode(entry.content, allowMalformed: true);
      /// 已移除脚本和样式元素的 XHTML 文本。
      final String safeHtml = html
          .replaceAll(RegExp(r'<\s*script\b[^>]*>.*?<\s*/\s*script\s*>', caseSensitive: false, dotAll: true), '')
          .replaceAll(RegExp(r'<\s*style\b[^>]*>.*?<\s*/\s*style\s*>', caseSensitive: false, dotAll: true), '');
      /// 已移除脚本和样式后的块级换行文本。
      final String withBreaks = safeHtml
          .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'</\s*(p|div|li|h[1-6])\s*>', caseSensitive: false), '\n');
      /// 已去除脚本、样式和标签的正文文本。
      final String text = html_parser.parseFragment(withBreaks).text ?? '';
      return text
          .replaceAll('\u00A0', ' ')
          .replaceAll(RegExp(r'[ \t]+\n'), '\n')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
    });
  }

  /// 从章节 JSON 变量恢复并校验归档相对路径。
  String _entryPathFromChapter(BookChapter chapter) {
    /// 持久化章节变量。
    final String? source = chapter.variable;
    if (source == null || source.trim().isEmpty) {
      throw const LocalBookException('EPUB 章节缺少资源地址，请重新导入');
    }
    try {
      /// 章节变量 JSON 根值。
      final Object? decoded = jsonDecode(source);
      if (decoded is Map<Object?, Object?>) {
        /// EPUB 条目路径字段。
        final Object? value = decoded['entryPath'];
        if (value is String && _isSafeEntryPath(value)) {
          return value;
        }
      }
    } catch (error) {
      throw const LocalBookException('EPUB 章节资源地址已经损坏，请重新导入');
    }
    throw const LocalBookException('EPUB 章节资源地址无效，请重新导入');
  }
}

/// 保存后台 EPUB 解析后的书名、作者和 spine 目录。
final class _EpubPayload {
  /// 创建可跨 isolate 返回的 EPUB 解析结果。
  const _EpubPayload({required this.title, required this.author, required this.chapters});

  /// OPF 元数据书名。
  final String title;

  /// OPF 元数据作者。
  final String author;

  /// 按 OPF spine 排序的章节。
  final List<_EpubChapter> chapters;
}

/// 保存单个 EPUB spine 章节事实。
final class _EpubChapter {
  /// 创建 EPUB 章节。
  const _EpubChapter({required this.entryPath, required this.title});

  /// 归档内已归一化的 XHTML 路径。
  final String entryPath;

  /// XHTML 标题或文件名回退。
  final String title;
}

/// 保存 OPF manifest 的单个资源。
final class _EpubManifestItem {
  /// 创建 manifest 资源描述。
  const _EpubManifestItem({required this.href, required this.mediaType});

  /// 相对于 OPF 的资源路径。
  final String href;

  /// OPF 声明的媒体类型。
  final String mediaType;
}

/// 从磁盘解析完整 EPUB 容器；调用方保证运行于后台 isolate。
_EpubPayload _parseEpubFile(String filePath) {
  /// 解码后的 ZIP 归档。
  final Archive archive = ZipDecoder().decodeBytes(File(filePath).readAsBytesSync(), verify: true);
  _validateArchive(archive);
  /// EPUB 容器索引文件。
  final ArchiveFile? container = archive.find('META-INF/container.xml');
  if (container == null) {
    throw const LocalBookException('EPUB 缺少 META-INF/container.xml');
  }
  /// 容器 XML 文本。
  final String containerXml = utf8.decode(container.content, allowMalformed: false);
  /// OPF 根文件地址匹配。
  final RegExpMatch? rootFileMatch = RegExp(
    r'''full-path\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(containerXml);
  /// 归一化 OPF 路径。
  final String? opfPath = rootFileMatch?.group(1)?.replaceAll('\\', '/');
  if (opfPath == null || !_isSafeEntryPath(opfPath)) {
    throw const LocalBookException('EPUB container.xml 未提供有效 OPF 地址');
  }
  /// OPF 归档条目。
  final ArchiveFile? opfEntry = archive.find(opfPath);
  if (opfEntry == null) {
    throw const LocalBookException('EPUB 声明的 OPF 文件不存在');
  }
  /// OPF XML 文本。
  final String opf = utf8.decode(opfEntry.content, allowMalformed: true);
  /// OPF 所在目录。
  final String opfDirectory = path.posix.dirname(opfPath);
  /// manifest id 到资源描述映射。
  final Map<String, _EpubManifestItem> manifest = <String, _EpubManifestItem>{};
  for (final RegExpMatch itemMatch in RegExp(r'<\s*item\b[^>]*>', caseSensitive: false).allMatches(opf)) {
    /// 当前 item 标签文本。
    final String tag = itemMatch.group(0) ?? '';
    /// 当前 item 属性映射。
    final Map<String, String> attributes = _xmlAttributes(tag);
    /// manifest 资源 ID。
    final String? id = attributes['id'];
    /// manifest 相对地址。
    final String? href = attributes['href'];
    if (id != null && href != null) {
      manifest[id] = _EpubManifestItem(
        href: href,
        mediaType: attributes['media-type'] ?? '',
      );
    }
  }
  /// OPF spine idref 顺序。
  final List<String> spineIds = RegExp(r'<\s*itemref\b[^>]*>', caseSensitive: false)
      .allMatches(opf)
      .map((RegExpMatch match) => _xmlAttributes(match.group(0) ?? '')['idref'])
      .whereType<String>()
      .toList(growable: false);
  if (spineIds.isEmpty) {
    throw const LocalBookException('EPUB OPF 不包含可阅读 spine');
  }
  /// 按 spine 建立的最终目录。
  final List<_EpubChapter> chapters = <_EpubChapter>[];
  for (final String id in spineIds) {
    /// 当前 spine 对应 manifest 资源。
    final _EpubManifestItem? item = manifest[id];
    if (item == null ||
        !(item.mediaType.contains('html') || item.href.toLowerCase().endsWith('.htm') || item.href.toLowerCase().endsWith('.html') || item.href.toLowerCase().endsWith('.xhtml'))) {
      continue;
    }
    /// 去除 fragment 后的归档资源路径。
    final String href = Uri.decodeComponent(item.href.split('#').first);
    /// 基于 OPF 目录归一化的资源地址。
    final String entryPath = path.posix.normalize(path.posix.join(opfDirectory, href));
    if (!_isSafeEntryPath(entryPath)) {
      throw const LocalBookException('EPUB 包含越界资源地址');
    }
    /// 当前 XHTML 条目。
    final ArchiveFile? xhtmlEntry = archive.find(entryPath);
    if (xhtmlEntry == null) {
      continue;
    }
    /// 用于提取标题的 XHTML 文本。
    final String xhtml = utf8.decode(xhtmlEntry.content, allowMalformed: true);
    /// 优先标题候选。
    final RegExpMatch? titleMatch = RegExp(
      r'<\s*(?:title|h1|h2)\b[^>]*>(.*?)<\s*/\s*(?:title|h1|h2)\s*>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(xhtml);
    /// 清理标签后的显示标题。
    final String title = html_parser.parseFragment(titleMatch?.group(1) ?? '').text?.trim() ?? '';
    chapters.add(
      _EpubChapter(
        entryPath: entryPath,
        title: title.isEmpty ? path.posix.basenameWithoutExtension(entryPath) : title,
      ),
    );
  }
  if (chapters.isEmpty) {
    throw const LocalBookException('EPUB spine 没有可读取的 XHTML 正文');
  }
  return _EpubPayload(
    title: _xmlElementText(opf, 'title'),
    author: _xmlElementText(opf, 'creator'),
    chapters: chapters,
  );
}

/// 验证归档条目数量、声明总大小、符号链接和路径安全。
void _validateArchive(Archive archive) {
  if (archive.length > EpubLocalBookParser.maxArchiveEntries) {
    throw const LocalBookException('EPUB 条目数量超过安全上限');
  }
  /// 所有文件声明的解压后总大小。
  int expandedBytes = 0;
  for (final ArchiveFile entry in archive.files) {
    if (!_isSafeEntryPath(entry.name) || entry.isSymbolicLink) {
      throw const LocalBookException('EPUB 包含不安全的归档路径或符号链接');
    }
    if (entry.isFile) {
      expandedBytes += entry.size;
      if (expandedBytes > EpubLocalBookParser.maxExpandedBytes) {
        throw const LocalBookException('EPUB 解压后大小超过安全上限');
      }
    }
  }
}

/// 判断归档条目是否为不会越过容器根目录的相对路径。
bool _isSafeEntryPath(String value) {
  /// 使用正斜杠归一化后的归档路径。
  final String normalized = path.posix.normalize(value.replaceAll('\\', '/'));
  return value.isNotEmpty &&
      !path.posix.isAbsolute(normalized) &&
      normalized != '..' &&
      !normalized.startsWith('../');
}

/// 从单个 XML 开始标签提取双引号或单引号属性。
Map<String, String> _xmlAttributes(String tag) {
  /// 当前标签属性映射。
  final Map<String, String> values = <String, String>{};
  for (final RegExpMatch match in RegExp(r'''([\w:-]+)\s*=\s*["']([^"']*)["']''').allMatches(tag)) {
    /// 属性名。
    final String? name = match.group(1);
    /// 属性值。
    final String? value = match.group(2);
    if (name != null && value != null) {
      values[name.toLowerCase()] = value;
    }
  }
  return values;
}

/// 从允许命名空间前缀的 XML 元素读取纯文本。
String _xmlElementText(String xml, String localName) {
  /// 目标元素匹配。
  final RegExpMatch? match = RegExp(
    '<\\s*(?:[\\w-]+:)?$localName\\b[^>]*>(.*?)<\\s*/\\s*(?:[\\w-]+:)?$localName\\s*>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(xml);
  return html_parser.parseFragment(match?.group(1) ?? '').text?.trim() ?? '';
}
