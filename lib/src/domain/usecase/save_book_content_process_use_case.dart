import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../gateway/book_content_process_gateway.dart';
import '../model/book_content_process.dart';

/// 保存用户高亮或下划线，对应 Android `SaveBookContentProcessUseCase` 的用户样式分支。
final class SaveBookContentProcessUseCase {
  /// 创建正文标注保存业务动作。
  const SaveBookContentProcessUseCase(this._gateway);

  /// 正文标注持久化边界。
  final BookContentProcessGateway _gateway;

  /// 使用稳定选区、前后文和样式创建一条用户正文标注。
  Future<BookContentProcess> execute({
    required String bookUrl,
    required int chapterIndex,
    required String chapterText,
    required ReaderTextSelection selection,
    required BookContentProcessKind kind,
  }) async {
    if (selection.start < 0 ||
        selection.end > chapterText.length ||
        selection.end <= selection.start) {
      throw const FormatException('选区位置已经失效，请重新选择');
    }
    /// 从当前完整正文重新截取的可信选区文本。
    final String selectedText =
        chapterText.substring(selection.start, selection.end);
    if (selectedText.trim().isEmpty) {
      throw const FormatException('不能标注空白正文');
    }
    /// 当前毫秒时间戳。
    final int now = DateTime.now().millisecondsSinceEpoch;
    /// 用于降低同一毫秒连续创建冲突的安全随机数。
    final int nonce = Random.secure().nextInt(0x7FFFFFFF);
    /// 不包含正文原文的稳定记录主键。
    final String id = sha256
        .convert(utf8.encode('$bookUrl:$chapterIndex:$now:$nonce'))
        .toString();
    /// 选区前文起点。
    final int beforeStart = max(0, selection.start - 40);
    /// 选区后文终点。
    final int afterEnd = min(chapterText.length, selection.end + 40);
    /// 规范化选区的摘要，兼容 Android `normalizedTextHash` 字段语义。
    final String normalizedHash = md5
        .convert(utf8.encode(_normalizeSelection(selectedText)))
        .toString();
    /// 同一本书内的下一个创建顺序。
    final int sortOrder = await _gateway.nextOrder(bookUrl);
    /// 根据标注类型生成的默认跨平台样式。
    final TextProcessStyle style = switch (kind) {
      BookContentProcessKind.userHighlight => const TextProcessStyle(
          backgroundColorValue: 0x66FFD54F,
        ),
      BookContentProcessKind.userUnderline => const TextProcessStyle(
          underlineColorValue: 0xFFE9A825,
          underlineWidth: 1.5,
        ),
    };
    /// 待持久化的完整正文标注。
    final BookContentProcess process = BookContentProcess(
      id: id,
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      kind: kind,
      anchor: TextProcessAnchor(
        chapterIndex: chapterIndex,
        chapterPosition: selection.start,
        selectedText: selectedText,
        contextBefore: chapterText.substring(beforeStart, selection.start),
        contextAfter: chapterText.substring(selection.end, afterEnd),
        normalizedTextHash: normalizedHash,
      ),
      style: style,
      enabled: true,
      sortOrder: sortOrder,
      status: BookContentProcess.activeStatus,
      createdAt: now,
      updatedAt: now,
    );
    await _gateway.upsert(process);
    return process;
  }

  /// 对齐 Android 内容处理锚点，去除普通和全角空白后生成摘要输入。
  String _normalizeSelection(String text) {
    return text
        .split('')
        .where((String character) =>
            character.trim().isNotEmpty && character != '　')
        .join();
  }
}
