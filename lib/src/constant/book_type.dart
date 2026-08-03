/// Android `BookType` 的 Dart 位掩码定义。
///
/// 每一位表达一种可组合的书籍能力；书源类型必须先经过
/// `bookTypeFromSourceType` 转换，不能直接写入书籍的 `type` 字段。
abstract final class BookType {
  /// 视频书籍位，对应 Android `BookType.video`。
  static const int video = 4;

  /// 文本书籍位，对应 Android `BookType.text`。
  static const int text = 8;

  /// 更新失败状态位，对应 Android `BookType.updateError`。
  static const int updateError = 16;

  /// 音频书籍位，对应 Android `BookType.audio`。
  static const int audio = 32;

  /// 图片或漫画书籍位，对应 Android `BookType.image`。
  static const int image = 64;

  /// 只提供文件下载能力的网站书籍位，对应 Android `BookType.webFile`。
  static const int webFile = 128;

  /// 本地书籍位，对应 Android `BookType.local`。
  static const int local = 256;

  /// 从压缩包解压得到的书籍位，对应 Android `BookType.archive`。
  static const int archive = 512;

  /// 尚未正式加入书架的临时阅读书籍位，对应 Android `BookType.notShelf`。
  static const int notShelf = 1024;

  /// 所有可由网络书源产生的主要书籍类型位。
  static const int allBookTypes = text | image | audio | webFile;

  /// 所有网络和本地主要书籍类型位。
  static const int allBookTypesWithLocal = allBookTypes | local;

  /// 判断 [value] 是否包含 [flag] 表达的全部类型位。
  static bool contains(int value, int flag) => (value & flag) == flag;

  /// 从可组合位掩码中提取决定阅读内容形态的主要类型位。
  ///
  /// 本地、临时和更新错误等附加位不影响内容兼容判断；Web 文件在同时携带文本位时
  /// 优先视为文件类型，避免被普通文本候选静默覆盖。
  static int primaryContentType(int value) {
    if (contains(value, image)) {
      return image;
    }
    if (contains(value, audio)) {
      return audio;
    }
    if (contains(value, webFile)) {
      return webFile;
    }
    if (contains(value, video)) {
      return video;
    }
    return text;
  }

  /// 判断两本书是否可以作为同一种阅读内容进行候选合并或换源。
  static bool hasCompatibleContentType(int left, int right) {
    return primaryContentType(left) == primaryContentType(right);
  }
}
