import 'package:path/path.dart' as path;
import 'package:pdfx/pdfx.dart';

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/local_book.dart';
import 'local_book_parser.dart';

/// 使用跨平台 PDFx 原生渲染边界读取页数并建立页面目录。
final class PdfLocalBookParser implements LocalBookParser {
  /// 创建无状态 PDF 元数据解析器。
  const PdfLocalBookParser();

  /// 当前解析器只负责 PDF。
  @override
  LocalBookFormat get format => LocalBookFormat.pdf;

  /// 打开 PDF 获取页数，每页建立独立稳定章节，随后立即释放文档句柄。
  @override
  Future<ParsedLocalBook> parse({
    required String filePath,
    required String bookUrl,
    required LocalBookFileReference reference,
    required String referenceJson,
  }) async {
    /// PDFx 打开的原生文档句柄。
    PdfDocument? document;
    try {
      document = await PdfDocument.openFile(filePath);
      if (document.pagesCount <= 0) {
        throw const LocalBookException('PDF 不包含可阅读页面');
      }
      /// 每页一个稳定目录项，页码从一开始、数据库索引从零开始。
      final List<BookChapter> chapters = List<BookChapter>.generate(
        document.pagesCount,
        (int index) => BookChapter(
          url: 'pdf:page:${index + 1}',
          title: '第 ${index + 1} 页',
          bookUrl: bookUrl,
          index: index,
          start: index,
          end: index + 1,
        ),
        growable: false,
      );
      /// 当前导入时间。
      final int now = DateTime.now().millisecondsSinceEpoch;
      return ParsedLocalBook(
        book: Book(
          bookUrl: bookUrl,
          origin: 'loc_book',
          originName: reference.displayName,
          name: path.basenameWithoutExtension(reference.displayName),
          author: '未知',
          type: 320,
          latestChapterTitle: chapters.last.title,
          latestChapterTime: now,
          lastCheckTime: now,
          totalChapterNum: chapters.length,
          canUpdate: false,
          variable: referenceJson,
        ),
        chapters: chapters,
      );
    } on LocalBookException {
      rethrow;
    } catch (error) {
      throw const LocalBookException('PDF 无法打开，文件可能损坏、加密或不受当前平台支持');
    } finally {
      await document?.close();
    }
  }

  /// PDF 必须走独立页面阅读器，禁止伪装为文本正文。
  @override
  Future<String> loadChapter({
    required String filePath,
    required Book book,
    required BookChapter chapter,
  }) {
    throw const LocalBookException('PDF 需要使用页面阅读器');
  }
}
