import 'book.dart';
import 'book_chapter.dart';

/// 本地书格式分类，保留 Android 当前支持格式的完整基线。
enum LocalBookFormat {
  /// 普通文本文件。
  txt,

  /// EPUB ZIP 容器电子书。
  epub,

  /// 掌阅 UMD 电子书。
  umd,

  /// 旧版 Mobipocket 电子书。
  mobi,

  /// Kindle AZW 电子书。
  azw,

  /// Kindle AZW3 电子书。
  azw3,

  /// 固定页面 PDF 文档。
  pdf,

  /// ZIP 导入容器。
  zip,

  /// RAR 导入容器。
  rar,

  /// 7Z 导入容器。
  sevenZip,
}

/// 描述系统文件选择器返回、尚未复制到应用目录的文件。
final class LocalBookPickedFile {
  /// 创建只包含导入所需平台事实的不可变文件描述。
  const LocalBookPickedFile({
    required this.path,
    required this.name,
    required this.size,
  });

  /// 当前选择结果可读取的临时或外部绝对路径。
  final String path;

  /// 系统提供的原始显示文件名。
  final String name;

  /// 系统提供的文件大小，单位为字节。
  final int size;
}

/// 保存应用私有本地书副本的稳定引用。
final class LocalBookFileReference {
  /// 创建可写入 Book.variable 的文件引用。
  const LocalBookFileReference({
    required this.relativePath,
    required this.displayName,
    required this.format,
    required this.contentHash,
    required this.size,
    required this.modifiedAt,
  });

  /// 相对于应用本地书根目录的路径，不保存易变化的沙盒绝对路径。
  final String relativePath;

  /// 用户导入时看到的原始文件名。
  final String displayName;

  /// 经文件签名或容器结构确认的格式。
  final LocalBookFormat format;

  /// 整个文件的 SHA-256 十六进制指纹。
  final String contentHash;

  /// 应用内副本大小，单位为字节。
  final int size;

  /// 应用内副本写入时间，Unix Epoch 毫秒。
  final int modifiedAt;
}

/// 保存一个解析器产出的书籍事实和完整目录。
final class ParsedLocalBook {
  /// 创建等待事务持久化的本地书解析结果。
  ParsedLocalBook({required this.book, required List<BookChapter> chapters})
    : chapters = List<BookChapter>.unmodifiable(chapters);

  /// 已填充本地稳定身份、元数据和格式字段的书籍。
  final Book book;

  /// 按稳定索引排序的完整章节目录。
  final List<BookChapter> chapters;
}

/// 表示单个文件完成导入后的结果。
final class LocalBookImportResult {
  /// 创建可供 UI 汇总展示的不可变导入结果。
  const LocalBookImportResult({required this.book, required this.updated});

  /// 已写入书架的本地书。
  final Book book;

  /// 是否命中了同一内容的既有书籍并执行更新。
  final bool updated;
}
