/// 应用可控错误的类别，供领域层、数据层和 UI 统一判断处理策略。
enum AppErrorKind {
  /// 输入或业务状态不满足操作要求。
  validation,

  /// 网络、存储或平台能力暂时不可用。
  infrastructure,

  /// 当前平台明确不支持目标能力。
  unsupported,

  /// 尚未归类但必须保留原始原因的错误。
  unknown,
}

/// 保存可向上层传递的稳定错误信息，同时保留原始原因便于诊断。
final class AppError implements Exception {
  /// 创建一个不丢失原因的应用错误。
  const AppError({
    required this.kind,
    required this.message,
    this.cause,
    this.stackTrace,
  });

  /// 错误类别，用于决定 UI 提示、重试或平台降级。
  final AppErrorKind kind;

  /// 可安全展示或记录的错误摘要，不应包含敏感数据。
  final String message;

  /// 底层原始错误对象，供诊断使用，不直接展示给用户。
  final Object? cause;

  /// 原始错误堆栈，供日志实现保留调用位置。
  final StackTrace? stackTrace;

  /// 返回稳定且不包含底层敏感内容的错误描述。
  @override
  String toString() => 'AppError(kind: $kind, message: $message)';
}
