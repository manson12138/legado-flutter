import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/local_book.dart';

/// 本地书探测、解析或正文读取失败时抛出的受控错误。
final class LocalBookException implements Exception {
  /// 创建可直接交给 UI 展示且不包含文件绝对路径的错误。
  const LocalBookException(this.message);

  /// 稳定错误摘要。
  final String message;

  /// 返回不泄漏本地路径的错误文本。
  @override
  String toString() => 'LocalBookException($message)';
}

/// 每种本地书格式必须实现的统一解析边界。
abstract interface class LocalBookParser {
  /// 当前解析器负责的格式。
  LocalBookFormat get format;

  /// 从应用内副本解析元数据和完整目录。
  Future<ParsedLocalBook> parse({
    required String filePath,
    required String bookUrl,
    required LocalBookFileReference reference,
    required String referenceJson,
  });

  /// 只读取目标章节正文，避免阅读器预加载整本书。
  Future<String> loadChapter({
    required String filePath,
    required Book book,
    required BookChapter chapter,
  });
}

/// 根据格式选择唯一解析器，并对尚未落地的 Android 格式明确报错。
final class LocalBookParserRegistry {
  /// 创建包含当前可执行解析器的注册表。
  LocalBookParserRegistry(List<LocalBookParser> parsers)
    : _parsers = <LocalBookFormat, LocalBookParser>{
        for (final LocalBookParser parser in parsers) parser.format: parser,
      };

  /// 格式到解析器的只读内部映射。
  final Map<LocalBookFormat, LocalBookParser> _parsers;

  /// 返回目标格式解析器；不存在时不伪装为成功。
  LocalBookParser requireParser(LocalBookFormat format) {
    /// 当前格式已经注册的解析器。
    final LocalBookParser? parser = _parsers[format];
    if (parser != null) {
      return parser;
    }
    throw LocalBookException('${_formatName(format)} 解析器尚未接入，当前文件不会被导入');
  }

  /// 返回面向用户的格式名称。
  String _formatName(LocalBookFormat format) {
    return switch (format) {
      LocalBookFormat.txt => 'TXT',
      LocalBookFormat.epub => 'EPUB',
      LocalBookFormat.umd => 'UMD',
      LocalBookFormat.mobi => 'MOBI',
      LocalBookFormat.azw => 'AZW',
      LocalBookFormat.azw3 => 'AZW3',
      LocalBookFormat.pdf => 'PDF',
      LocalBookFormat.zip => 'ZIP',
      LocalBookFormat.rar => 'RAR',
      LocalBookFormat.sevenZip => '7Z',
    };
  }
}
