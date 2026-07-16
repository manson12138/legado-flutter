import '../../help/logging/app_log_manager.dart';

/// 保存日志管理页可持续渲染的状态。
final class LogManagementUiState {
  /// 创建不可变日志管理状态。
  const LogManagementUiState({
    this.isLoading = false,
    this.files = const <AppLogFile>[],
    this.errorMessage,
  });

  /// 是否正在刷新文件列表或执行文件操作。
  final bool isLoading;

  /// 按最新修改时间优先排列的日志文件。
  final List<AppLogFile> files;

  /// 最近一次加载失败时展示的安全错误提示。
  final String? errorMessage;

  /// 复制状态并只替换指定字段。
  LogManagementUiState copyWith({
    bool? isLoading,
    List<AppLogFile>? files,
    String? errorMessage,
    bool clearError = false,
  }) {
    return LogManagementUiState(
      isLoading: isLoading ?? this.isLoading,
      files: files ?? this.files,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 定义日志管理页允许发送的全部用户意图。
sealed class LogManagementIntent {
  /// 限制意图只能由本文件中的明确类型创建。
  const LogManagementIntent();
}

/// 请求重新读取日志文件列表。
final class ReloadLogFilesIntent extends LogManagementIntent {
  /// 创建刷新意图。
  const ReloadLogFilesIntent();
}

/// 请求读取并查看一个日志文件。
final class ViewLogFileIntent extends LogManagementIntent {
  /// 创建包含目标文件的查看意图。
  const ViewLogFileIntent(this.file);

  /// 需要查看的日志文件。
  final AppLogFile file;
}

/// 请求调用系统面板分享一个日志文件。
final class ShareLogFileIntent extends LogManagementIntent {
  /// 创建包含目标文件的分享意图。
  const ShareLogFileIntent(this.file);

  /// 需要分享的日志文件。
  final AppLogFile file;
}

/// 请求把一个日志文件回显到 ADB。
final class EchoLogFileIntent extends LogManagementIntent {
  /// 创建包含目标文件的 ADB 回显意图。
  const EchoLogFileIntent(this.file);

  /// 需要回显的日志文件。
  final AppLogFile file;
}

/// 请求删除一个已经由页面确认的日志文件。
final class DeleteLogFileIntent extends LogManagementIntent {
  /// 创建包含目标文件的删除意图。
  const DeleteLogFileIntent(this.file);

  /// 需要删除的日志文件。
  final AppLogFile file;
}

/// 请求删除全部已经由页面确认的日志文件。
final class DeleteAllLogFilesIntent extends LogManagementIntent {
  /// 创建全部删除意图。
  const DeleteAllLogFilesIntent();
}

/// 定义日志管理页交给路由层执行的一次性副作用。
sealed class LogManagementEffect {
  /// 限制副作用只能由本文件中的明确类型创建。
  const LogManagementEffect();
}

/// 请求显示短暂操作结果。
final class ShowLogMessageEffect extends LogManagementEffect {
  /// 创建包含用户可读文本的消息副作用。
  const ShowLogMessageEffect(this.message);

  /// 需要显示的消息。
  final String message;
}

/// 请求打开只读日志查看器。
final class ShowLogContentEffect extends LogManagementEffect {
  /// 创建日志内容查看副作用。
  const ShowLogContentEffect({required this.file, required this.content});

  /// 当前查看的日志文件。
  final AppLogFile file;

  /// 已完整读取的日志内容。
  final String content;
}

/// 请求通过系统分享面板发送日志文件。
final class ShareLogFileEffect extends LogManagementEffect {
  /// 创建包含目标文件的分享副作用。
  const ShareLogFileEffect(this.file);

  /// 需要交给系统分享的日志文件。
  final AppLogFile file;
}
