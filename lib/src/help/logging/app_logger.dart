/// 【扫码诊断日志】扫一扫添加书源全链路统一日志标识。
const String bookSourceQrScanLogTag = '[BOOK_SOURCE_QR_SCAN]';

/// 普通应用日志在 Android Logcat 中使用的固定 Tag。
const String appLogTag = 'LEGADO_APP';

/// 页面路由跳转日志在 Android Logcat 中使用的固定 Tag。
const String navigationLogTag = 'LEGADO_NAV';

/// 网络请求日志在 Android Logcat 中使用的固定 Tag。
const String networkLogTag = 'LEGADO_HTTP';

/// 数据库操作日志在 Android Logcat 中使用的固定 Tag。
const String databaseLogTag = 'LEGADO_DB';

/// 二维码添加书源全链路在 Android Logcat 中使用的固定 Tag。
const String bookSourceQrLogTag = 'LEGADO_QR_SOURCE';

/// 【搜书诊断日志】搜索页面、搜索任务生命周期和结果合并使用的 Logcat Tag。
const String bookSearchUiLogTag = 'BOOK_SEARCH_UI';

/// 【搜书诊断日志】单书源请求、规则解析和失败分类使用的 Logcat Tag。
const String bookSearchSourceLogTag = 'BOOK_SEARCH_SOURCE';

/// 【搜书诊断日志】搜索结果进入详情及详情字段加载使用的 Logcat Tag。
const String bookDetailLogTag = 'BOOK_DETAIL';

/// 【搜书诊断日志】书籍目录请求、分页解析和持久化使用的 Logcat Tag。
const String bookTocLogTag = 'BOOK_TOC';

/// M11 整书换源搜索、候选预览、事务提交和路由切换共用的 Logcat Tag。
const String bookSourceChangeLogTag = 'BOOK_SOURCE_CHANGE';

/// 【搜书诊断日志】从书架点击书籍到阅读器初始化完成使用的 Logcat Tag。
const String bookReaderEntryLogTag = 'BOOK_READER_ENTRY';

/// 【搜书诊断日志】章节缓存、网络正文、处理和预加载使用的 Logcat Tag。
const String bookReaderContentLogTag = 'BOOK_READER_CONTENT';

/// 【FLUTTER_JS_COMPAT_LOG】JavaScript 兼容诊断日志统一标识，问题解决后可按此标识完整移除。
const String javaScriptCompatibilityDebugLogMarker = 'FLUTTER_JS_COMPAT_LOG';

/// 【扫码诊断日志】Dio 请求 `extra` 中传递业务日志上下文的固定键。
const String networkRequestLogContextExtraKey = '_legadoNetworkLogContext';

/// 根据稳定业务标识把未显式指定的日志自动归入对应 Logcat Tag。
String resolveAppLogTag({required String message, required String requestedTag}) {
  if (requestedTag == appLogTag && message.contains(bookSourceQrScanLogTag)) {
    return bookSourceQrLogTag;
  }
  return requestedTag;
}

/// 【搜书诊断日志】把可能包含用户内容或完整 URL 的值转换为仅供本次运行关联的诊断 ID。
String appLogDiagnosticId(String value) {
  return value.hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}

/// 【搜书诊断日志】压平换行并限制长度，避免不可信书源名称破坏单条日志结构。
String appLogSafeLabel(String value, {int maximumLength = 80}) {
  /// 去除首尾空白并把连续空白压成单个空格后的标签。
  final String normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.length <= maximumLength) {
    return normalized;
  }
  return '${normalized.substring(0, maximumLength)}…';
}

/// 【FLUTTER_JS_COMPAT_LOG】脱敏并压平 JavaScript 引擎错误摘要，禁止脚本正文和认证值进入日志。
String appLogSafeJavaScriptDiagnostic(String value, {int maximumLength = 600}) {
  /// 【FLUTTER_JS_COMPAT_LOG】QuickJS 语法错误中的单个 token，可安全保留用于兼容定位。
  final String? unexpectedToken = RegExp(
    r'''unexpected token:\s*([^\s]{1,20})''',
    caseSensitive: false,
  ).firstMatch(value)?.group(1);
  /// 【FLUTTER_JS_COMPAT_LOG】隐藏引号内的长文本，避免响应正文或整段脚本随异常进入日志。
  String sanitized = value.replaceAll(
    RegExp(r'''(["']).{80,}?\1''', dotAll: true),
    '<LONG_VALUE_REDACTED>',
  );
  /// 【FLUTTER_JS_COMPAT_LOG】隐藏常见认证、Cookie、Token、密码和密钥字段的值。
  final RegExp sensitiveFieldPattern = RegExp(
    r'''((?:authorization|proxy-authorization|cookie|set-cookie|access[_-]?token|refresh[_-]?token|csrf[_-]?token|token|password|passwd|secret|api[_-]?key|session[_-]?id)\s*[:=]\s*)([^\s,;]+)''',
    caseSensitive: false,
  );
  sanitized = sanitized.replaceAllMapped(sensitiveFieldPattern, (Match match) {
    /// 【FLUTTER_JS_COMPAT_LOG】保留敏感字段名称，便于判断失败表面但不保留其值。
    final String prefix = match.group(1) ?? '';
    return '${prefix}[REDACTED]';
  });
  if (unexpectedToken != null) {
    sanitized = sanitized.replaceFirst(
      RegExp(r'''unexpected token:\s*\[REDACTED\]''', caseSensitive: false),
      'unexpected token: $unexpectedToken',
    );
  }
  /// 【FLUTTER_JS_COMPAT_LOG】隐藏没有字段名但带认证方案前缀的凭据。
  sanitized = sanitized.replaceAll(
    RegExp(r'''\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+''', caseSensitive: false),
    '[AUTHORIZATION_REDACTED]',
  );
  /// 【FLUTTER_JS_COMPAT_LOG】去除 URL 查询参数，保留域名和路径用于判断兼容位置。
  sanitized = sanitized.replaceAllMapped(
    RegExp(r'''https?://[^\s?'"<>]+\?[^\s'"<>]+''', caseSensitive: false),
    (Match match) {
      /// 【FLUTTER_JS_COMPAT_LOG】当前 URL 中问号之前的不敏感定位部分。
      final String url = match.group(0) ?? '';
      return '${url.split('?').first}?[QUERY_REDACTED]';
    },
  );
  /// 【FLUTTER_JS_COMPAT_LOG】压平换行和连续空白，保证每次错误只占一条结构化日志。
  final String normalized = sanitized.trim().replaceAll(RegExp(r'\s+'), ' ');
  return normalized.length <= maximumLength
      ? normalized
      : '${normalized.substring(0, maximumLength)}…';
}

/// 应用日志严重级别，用于让输出实现选择合适的展示或持久化策略。
enum AppLogLevel {
  /// 开发阶段诊断信息，不能包含账号、Cookie、Token 或正文隐私数据。
  debug,

  /// 正常生命周期或重要状态变化信息。
  info,

  /// 可恢复但需要关注的异常状态。
  warning,

  /// 导致当前操作失败或越过全局边界的错误。
  error,

  /// 应用无法继续当前关键流程时使用的最高优先级。
  fatal,
}

/// 定义应用统一日志能力，业务层不直接依赖控制台或第三方日志库。
abstract interface class AppLogger {
  /// 记录开发阶段诊断信息。
  void debug({required String message, String tag = appLogTag});

  /// 记录正常的重要状态变化。
  void info({required String message, String tag = appLogTag});

  /// 记录可恢复异常，并可附带原始错误对象。
  void warning({
    required String message,
    String tag = appLogTag,
    Object? error,
  });

  /// 记录导致操作失败的错误及可选堆栈。
  void error({
    required String message,
    String tag = appLogTag,
    Object? error,
    StackTrace? stackTrace,
  });

  /// 记录导致关键流程无法继续的严重错误及可选堆栈。
  void fatal({
    required String message,
    String tag = appLogTag,
    Object? error,
    StackTrace? stackTrace,
  });
}
