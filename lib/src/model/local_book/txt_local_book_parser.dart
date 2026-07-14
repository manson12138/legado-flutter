import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:enough_convert/enough_convert.dart';
import 'package:path/path.dart' as path;

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/local_book.dart';
import 'local_book_parser.dart';

/// 解析 TXT 编码、默认章节目录和目标字符范围正文。
final class TxtLocalBookParser implements LocalBookParser {
  /// 创建无状态 TXT 解析器。
  const TxtLocalBookParser();

  /// 默认目录表达式，覆盖常见“第…章/回/卷/节/部/篇”中文标题。
  static final RegExp _chapterPattern = RegExp(
    r'^\s*(第.{1,24}[章回卷节部篇][^\r\n]{0,60})\s*$',
    multiLine: true,
  );

  /// 当前解析器只负责 TXT。
  @override
  LocalBookFormat get format => LocalBookFormat.txt;

  /// 在后台 isolate 解码文本并生成字符范围目录。
  @override
  Future<ParsedLocalBook> parse({
    required String filePath,
    required String bookUrl,
    required LocalBookFileReference reference,
    required String referenceJson,
  }) async {
    /// 后台解码得到的正文、字符集和章节范围。
    final _TxtParsePayload payload = await Isolate.run<_TxtParsePayload>(() {
      /// 应用内 TXT 完整字节；解析运行在后台 isolate。
      final Uint8List bytes = File(filePath).readAsBytesSync();
      /// 自动识别后的文本与字符集。
      final _DecodedTxt decoded = _decodeTxt(bytes);
      /// 从默认规则扫描出的章节范围。
      final List<_TxtChapterRange> ranges = _buildTxtRanges(decoded.text);
      return _TxtParsePayload(
        charset: decoded.charset,
        textLength: decoded.text.length,
        chapters: ranges,
      );
    });
    /// 从文件名移除扩展名后的书名和作者候选。
    final ({String name, String author}) naming = _parseFileName(reference.displayName);
    /// 持久化章节列表。
    final List<BookChapter> chapters = payload.chapters.indexed.map(((int, _TxtChapterRange) entry) {
      /// 当前章节的稳定顺序和字符范围。
      final int index = entry.$1;
      /// 当前章节范围。
      final _TxtChapterRange range = entry.$2;
      return BookChapter(
        url: 'txt:$index:${range.start}-${range.end}',
        title: range.title,
        bookUrl: bookUrl,
        index: index,
        start: range.start,
        end: range.end,
        wordCount: '${range.end - range.start}',
      );
    }).toList(growable: false);
    /// 当前导入时间。
    final int now = DateTime.now().millisecondsSinceEpoch;
    return ParsedLocalBook(
      book: Book(
        bookUrl: bookUrl,
        origin: 'loc_book',
        originName: reference.displayName,
        name: naming.name,
        author: naming.author,
        charset: payload.charset,
        type: 264,
        latestChapterTitle: chapters.last.title,
        latestChapterTime: now,
        lastCheckTime: now,
        totalChapterNum: chapters.length,
        wordCount: '${payload.textLength}',
        canUpdate: false,
        variable: referenceJson,
      ),
      chapters: chapters,
    );
  }

  /// 在后台 isolate 解码文件，并只返回目标章节字符范围。
  @override
  Future<String> loadChapter({
    required String filePath,
    required Book book,
    required BookChapter chapter,
  }) async {
    /// 章节字符起点。
    final int? start = chapter.start;
    /// 章节字符终点。
    final int? end = chapter.end;
    if (start == null || end == null || start < 0 || end < start) {
      throw const LocalBookException('TXT 章节缺少有效字符范围，请重新导入');
    }
    return Isolate.run<String>(() {
      /// 后台 isolate 读取的 TXT 字节。
      final Uint8List bytes = File(filePath).readAsBytesSync();
      /// 按导入时相同探测逻辑恢复完整文本。
      final String text = _decodeTxt(bytes, preferredCharset: book.charset).text;
      if (start > text.length || end > text.length) {
        throw const LocalBookException('TXT 文件内容已经变化，请重新导入');
      }
      return text.substring(start, end).trim();
    });
  }

  /// 从“书名 作者”或“书名_作者”文件名提取基础元数据。
  ({String name, String author}) _parseFileName(String displayName) {
    /// 不含扩展名的原始名称。
    final String baseName = path.basenameWithoutExtension(displayName).trim();
    /// Android 常见本地书文件名分隔符。
    final RegExpMatch? match = RegExp(r'^(.+?)[_\-（(]\s*(?:作者[:：]?\s*)?([^）)]+)[）)]?$').firstMatch(baseName);
    /// 书名候选。
    final String name = match?.group(1)?.trim() ?? baseName;
    /// 作者候选；文件名没有作者时使用 Android 兼容的“未知”。
    final String author = match?.group(2)?.trim() ?? '未知';
    return (name: name.isEmpty ? '未命名本地书' : name, author: author.isEmpty ? '未知' : author);
  }
}

/// 保存 TXT 自动解码结果。
final class _DecodedTxt {
  /// 创建后台 isolate 内部解码结果。
  const _DecodedTxt({required this.text, required this.charset});

  /// 已移除 BOM 的完整文本。
  final String text;

  /// 实际采用的稳定字符集名称。
  final String charset;
}

/// 保存一个 TXT 章节在解码文本中的字符范围。
final class _TxtChapterRange {
  /// 创建半开区间章节范围。
  const _TxtChapterRange({required this.title, required this.start, required this.end});

  /// 章节显示标题。
  final String title;

  /// 正文起始字符位置。
  final int start;

  /// 正文结束字符位置，不包含该位置字符。
  final int end;
}

/// 保存从后台 isolate 返回的 TXT 目录事实。
final class _TxtParsePayload {
  /// 创建可跨 isolate 传递的解析载荷。
  const _TxtParsePayload({required this.charset, required this.textLength, required this.chapters});

  /// 自动识别字符集。
  final String charset;

  /// 解码后完整字符数。
  final int textLength;

  /// 默认规则生成的章节范围。
  final List<_TxtChapterRange> chapters;
}

/// 按 BOM、严格 UTF-8 和中文兼容编码顺序解码 TXT。
_DecodedTxt _decodeTxt(Uint8List bytes, {String? preferredCharset}) {
  if (preferredCharset == 'utf-8') {
    return _DecodedTxt(text: _stripBom(utf8.decode(bytes, allowMalformed: false)), charset: 'utf-8');
  }
  if (preferredCharset == 'utf-16le') {
    return _DecodedTxt(text: _decodeUtf16(bytes, littleEndian: true), charset: 'utf-16le');
  }
  if (preferredCharset == 'utf-16be') {
    return _DecodedTxt(text: _decodeUtf16(bytes, littleEndian: false), charset: 'utf-16be');
  }
  if (preferredCharset == 'big5') {
    return _DecodedTxt(text: big5.decode(bytes), charset: 'big5');
  }
  if (preferredCharset == 'gbk') {
    return _DecodedTxt(text: gbk.decode(bytes), charset: 'gbk');
  }
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return _DecodedTxt(text: utf8.decode(bytes.sublist(3), allowMalformed: false), charset: 'utf-8');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _DecodedTxt(text: _decodeUtf16(bytes.sublist(2), littleEndian: true), charset: 'utf-16le');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _DecodedTxt(text: _decodeUtf16(bytes.sublist(2), littleEndian: false), charset: 'utf-16be');
  }
  try {
    return _DecodedTxt(text: utf8.decode(bytes, allowMalformed: false), charset: 'utf-8');
  } on FormatException {
    return _DecodedTxt(text: gbk.decode(bytes), charset: 'gbk');
  }
}

/// 解码带明确字节序的 UTF-16 文本。
String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  /// UTF-16 码元列表。
  final List<int> codeUnits = <int>[];
  for (int index = 0; index + 1 < bytes.length; index += 2) {
    /// 当前双字节码元。
    final int unit = littleEndian
        ? bytes[index] | (bytes[index + 1] << 8)
        : (bytes[index] << 8) | bytes[index + 1];
    codeUnits.add(unit);
  }
  return String.fromCharCodes(codeUnits);
}

/// 移除解码后残留的 Unicode BOM。
String _stripBom(String text) => text.startsWith('\uFEFF') ? text.substring(1) : text;

/// 使用默认规则生成章节字符范围；无匹配时保留单章。
List<_TxtChapterRange> _buildTxtRanges(String text) {
  /// 所有章节标题匹配。
  final List<RegExpMatch> matches = TxtLocalBookParser._chapterPattern.allMatches(text).toList(growable: false);
  if (matches.isEmpty) {
    return <_TxtChapterRange>[
      _TxtChapterRange(title: '正文', start: 0, end: text.length),
    ];
  }
  /// 从标题匹配构造的章节范围。
  final List<_TxtChapterRange> chapters = <_TxtChapterRange>[];
  if (matches.first.start > 0 && text.substring(0, matches.first.start).trim().isNotEmpty) {
    chapters.add(_TxtChapterRange(title: '前言', start: 0, end: matches.first.start));
  }
  for (final (int, RegExpMatch) entry in matches.indexed) {
    /// 当前标题匹配序号。
    final int index = entry.$1;
    /// 当前标题匹配。
    final RegExpMatch match = entry.$2;
    /// 下一标题起点或文件末尾。
    final int end = index + 1 < matches.length ? matches[index + 1].start : text.length;
    chapters.add(
      _TxtChapterRange(
        title: match.group(1)?.trim() ?? '第 ${index + 1} 章',
        start: match.end,
        end: end,
      ),
    );
  }
  return chapters;
}
