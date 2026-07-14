import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/local_book.dart';
import 'local_book_parser.dart';

/// 按 Android 内置 UmdReader 的分段语义解析文本型 UMD。
final class UmdLocalBookParser implements LocalBookParser {
  /// 创建无状态 UMD 解析器。
  const UmdLocalBookParser();

  /// 当前解析器只负责 UMD。
  @override
  LocalBookFormat get format => LocalBookFormat.umd;

  /// 在后台 isolate 读取 UMD 元数据、章节偏移、标题和压缩正文。
  @override
  Future<ParsedLocalBook> parse({
    required String filePath,
    required String bookUrl,
    required LocalBookFileReference reference,
    required String referenceJson,
  }) async {
    /// 后台 UMD 解析结果。
    final _UmdPayload payload = await Isolate.run<_UmdPayload>(() => _parseUmd(filePath));
    /// 与 UMD 章节偏移对应的数据库目录。
    final List<BookChapter> chapters = payload.titles.indexed.map(((int, String) entry) {
      /// 当前章节零基索引。
      final int index = entry.$1;
      /// 当前章节正文起始 UTF-16 字节偏移。
      final int start = payload.offsets[index];
      /// 当前章节正文结束 UTF-16 字节偏移。
      final int end = index + 1 < payload.offsets.length
          ? payload.offsets[index + 1]
          : payload.contentLength;
      return BookChapter(
        url: 'umd:chapter:$index',
        title: entry.$2.trim().isEmpty ? '第 ${index + 1} 章' : entry.$2.trim(),
        bookUrl: bookUrl,
        index: index,
        start: start,
        end: end,
        wordCount: '${(end - start) ~/ 2}',
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
        kind: payload.kind.trim().isEmpty ? null : payload.kind.trim(),
        type: 264,
        latestChapterTitle: chapters.last.title,
        latestChapterTime: now,
        lastCheckTime: now,
        totalChapterNum: chapters.length,
        wordCount: '${payload.contentLength ~/ 2}',
        canUpdate: false,
        variable: referenceJson,
      ),
      chapters: chapters,
    );
  }

  /// 在后台 isolate 重新解压 UMD，并只返回目标章节字节范围。
  @override
  Future<String> loadChapter({
    required String filePath,
    required Book book,
    required BookChapter chapter,
  }) async {
    /// 章节正文起始 UTF-16 字节偏移。
    final int? start = chapter.start;
    /// 章节正文结束 UTF-16 字节偏移。
    final int? end = chapter.end;
    if (start == null || end == null || start < 0 || end < start) {
      throw const LocalBookException('UMD 章节缺少有效正文范围，请重新导入');
    }
    return Isolate.run<String>(() {
      /// 重新解析得到的 UMD 完整正文字节。
      final Uint8List content = _parseUmd(filePath).content;
      if (end > content.length) {
        throw const LocalBookException('UMD 文件内容已经变化，请重新导入');
      }
      return _decodeUtf16Le(content.sublist(start, end)).replaceAll('\u2029', '\n').trim();
    });
  }
}

/// 保存 UMD 元数据、目录偏移和解压正文。
final class _UmdPayload {
  /// 创建后台 UMD 解析载荷。
  const _UmdPayload({
    required this.title,
    required this.author,
    required this.kind,
    required this.titles,
    required this.offsets,
    required this.content,
  });

  /// UMD 标题元数据。
  final String title;

  /// UMD 作者元数据。
  final String author;

  /// UMD 书籍分类。
  final String kind;

  /// 章节标题列表。
  final List<String> titles;

  /// 每章在完整 UTF-16 正文中的起始字节偏移。
  final List<int> offsets;

  /// 拼接全部 zlib 数据块后的 UTF-16LE 正文字节。
  final Uint8List content;

  /// 完整正文实际字节数。
  int get contentLength => content.length;
}

/// 提供带越界检查的 UMD 小端字节游标。
final class _UmdCursor {
  /// 创建指向文件开头的游标。
  _UmdCursor(this.bytes);

  /// UMD 完整文件字节。
  final Uint8List bytes;

  /// 当前读取位置。
  int position = 0;

  /// 是否仍有可读取字节。
  bool get hasRemaining => position < bytes.length;

  /// 读取无符号单字节。
  int readUint8() {
    _require(1);
    return bytes[position++];
  }

  /// 读取小端无符号双字节。
  int readUint16Le() {
    _require(2);
    /// 当前双字节小端值。
    final int value = bytes[position] | (bytes[position + 1] << 8);
    position += 2;
    return value;
  }

  /// 读取小端四字节整数。
  int readInt32Le() {
    _require(4);
    /// 当前四字节小端值。
    final int value = bytes[position] |
        (bytes[position + 1] << 8) |
        (bytes[position + 2] << 16) |
        (bytes[position + 3] << 24);
    position += 4;
    return value;
  }

  /// 读取固定长度字节并推进游标。
  Uint8List readBytes(int length) {
    if (length < 0) {
      throw const LocalBookException('UMD 分段长度无效');
    }
    _require(length);
    /// 当前分段字节副本。
    final Uint8List value = Uint8List.fromList(bytes.sublist(position, position + length));
    position += length;
    return value;
  }

  /// 校验剩余字节数，损坏文件不会读取越界。
  void _require(int length) {
    if (position + length > bytes.length) {
      throw const LocalBookException('UMD 文件在分段中途结束');
    }
  }
}

/// 解析文本型 UMD 文件；调用方保证运行在后台 isolate。
_UmdPayload _parseUmd(String filePath) {
  /// 文件字节游标。
  final _UmdCursor cursor = _UmdCursor(File(filePath).readAsBytesSync());
  if (cursor.readInt32Le() != 0xDE9A9B89) {
    throw const LocalBookException('UMD 文件头无效');
  }
  /// UMD 标题元数据。
  String title = '';
  /// UMD 作者元数据。
  String author = '';
  /// UMD 分类元数据。
  String kind = '';
  /// 最近章节内容检查号。
  int additionalCheckNumber = 0;
  /// 上一个主分段类型，用于许可证和内容 ID 后恢复解析上下文。
  int previousSegmentType = -1;
  /// 章节起始字节偏移。
  final List<int> offsets = <int>[];
  /// 章节标题。
  final List<String> titles = <String>[];
  /// 解压后的正文数据块。
  final BytesBuilder contents = BytesBuilder(copy: false);
  /// 当前主循环标记字节。
  int marker = cursor.readUint8();
  while (marker == 0x23 && cursor.hasRemaining) {
    /// 当前主分段类型。
    int segmentType = cursor.readUint16Le();
    /// 当前主分段标志由 Android 解析器读取但不参与文本 UMD 逻辑。
    cursor.readUint8();
    /// 当前主分段有效载荷长度。
    final int sectionLength = cursor.readUint8() - 5;
    switch (segmentType) {
      case 1:
        /// UMD 类型必须为文本 1；另外两个随机字节不参与解析。
        final int umdType = cursor.readUint8();
        cursor.readBytes(2);
        if (umdType != 1) {
          throw const LocalBookException('当前 UMD 不是文本型书籍');
        }
      case 2:
        title = _decodeUtf16Le(cursor.readBytes(sectionLength));
      case 3:
        author = _decodeUtf16Le(cursor.readBytes(sectionLength));
      case 7:
        kind = _decodeUtf16Le(cursor.readBytes(sectionLength));
      case 11:
        cursor.readInt32Le();
      case 12:
        cursor.readInt32Le();
      case 14:
        cursor.readUint8();
      case 15:
        cursor.readBytes(sectionLength);
      case 129 || 131 || 132:
        additionalCheckNumber = cursor.readInt32Le();
      case 130:
        cursor.readUint8();
        additionalCheckNumber = cursor.readInt32Le();
      case 135:
        cursor.readBytes(sectionLength);
      case 241:
        cursor.readBytes(sectionLength);
      default:
        cursor.readBytes(sectionLength);
    }
    if (segmentType == 241 || segmentType == 10) {
      segmentType = previousSegmentType;
    }
    marker = cursor.hasRemaining ? cursor.readUint8() : 0;
    while (marker == 0x24 && cursor.hasRemaining) {
      /// 附加分段检查号。
      final int checkNumber = cursor.readInt32Le();
      /// 附加分段有效载荷长度。
      final int additionalLength = cursor.readInt32Le() - 9;
      switch (segmentType) {
        case 129:
          cursor.readBytes(additionalLength);
        case 130:
          cursor.readBytes(additionalLength);
        case 131:
          if (additionalLength % 4 != 0) {
            throw const LocalBookException('UMD 章节偏移分段长度无效');
          }
          for (int index = 0; index < additionalLength ~/ 4; index += 1) {
            offsets.add(cursor.readInt32Le());
          }
        case 132:
          if (additionalCheckNumber != checkNumber) {
            /// 当前 zlib 正文块。
            final Uint8List compressed = cursor.readBytes(additionalLength);
            contents.add(ZLibDecoder().decodeBytes(compressed));
          } else {
            /// 当前标题分段已消费字节数。
            int consumed = 0;
            while (consumed < additionalLength) {
              /// 当前 UTF-16 标题字节数。
              final int length = cursor.readUint8();
              consumed += 1;
              titles.add(_decodeUtf16Le(cursor.readBytes(length)));
              consumed += length;
            }
          }
        default:
          cursor.readBytes(additionalLength);
      }
      marker = cursor.hasRemaining ? cursor.readUint8() : 0;
    }
    previousSegmentType = segmentType;
  }
  /// 合并后的完整正文字节。
  final Uint8List content = contents.takeBytes();
  if (titles.isEmpty || offsets.isEmpty || titles.length != offsets.length || content.isEmpty) {
    throw const LocalBookException('UMD 缺少完整章节标题、偏移或正文');
  }
  for (final int offset in offsets) {
    if (offset < 0 || offset > content.length || offset.isOdd) {
      throw const LocalBookException('UMD 章节偏移越界');
    }
  }
  return _UmdPayload(
    title: title,
    author: author,
    kind: kind,
    titles: titles,
    offsets: offsets,
    content: content,
  );
}

/// 将 UMD 使用的 UTF-16LE 字节转换为 Dart 字符串。
String _decodeUtf16Le(List<int> bytes) {
  /// UTF-16 码元列表。
  final List<int> codeUnits = <int>[];
  for (int index = 0; index + 1 < bytes.length; index += 2) {
    codeUnits.add(bytes[index] | (bytes[index + 1] << 8));
  }
  return String.fromCharCodes(codeUnits).replaceAll('\u0000', '');
}
