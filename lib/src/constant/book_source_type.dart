import 'book_type.dart';

/// Android `BookSourceType` 的 Dart 数值定义。
///
/// 这些值描述书源类别，不是 `Book.type` 使用的位掩码。
abstract final class BookSourceType {
  /// 普通文本书源，对应 Android `BookSourceType.default`。
  static const int text = 0;

  /// 音频书源，对应 Android `BookSourceType.audio`。
  static const int audio = 1;

  /// 图片或漫画书源，对应 Android `BookSourceType.image`。
  static const int image = 2;

  /// 只提供文件下载能力的书源，对应 Android `BookSourceType.file`。
  static const int file = 3;

  /// Flutter 导入边界保留的视频扩展类型；Android 基准未把它列入 `BookSourceType`。
  static const int video = 4;
}

/// 把书源类别转换为 Android 兼容的书籍位掩码。
///
/// 对应 Android `BookSourceExtensions.getBookType()`；未知类型按原实现回退为文本书籍，
/// 文件书源同时保留文本能力和 Web 文件能力。
int bookTypeFromSourceType(int sourceType) {
  return switch (sourceType) {
    BookSourceType.audio => BookType.audio,
    BookSourceType.image => BookType.image,
    BookSourceType.file => BookType.text | BookType.webFile,
    _ => BookType.text,
  };
}
