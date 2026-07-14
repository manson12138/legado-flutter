/// 表示按 URL 键保存的 Cookie 文本，对应 Android `data.entities.Cookie`。
final class Cookie {
  /// 创建不可变 Cookie 记录。
  const Cookie({required this.url, required this.cookie});

  /// Cookie 作用域键，也是表主键；包含 `|` 的历史键保留 OkHttp Cookie 语义。
  final String url;
  /// 原始 Cookie 请求头文本；不得写入日志。
  final String cookie;
}
