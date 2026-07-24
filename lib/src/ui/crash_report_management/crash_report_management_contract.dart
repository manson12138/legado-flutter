import '../../help/crash_reporting/crash_report_manager.dart';

/// 崩溃报告管理页的不可变渲染状态。
final class CrashReportManagementUiState {
  /// 创建崩溃报告页面状态。
  const CrashReportManagementUiState({this.isLoading = false, this.reports = const <CrashReportFile>[], this.errorMessage});

  /// 是否正在执行列表或文件操作。
  final bool isLoading;
  /// 按发生时间倒序的报告摘要。
  final List<CrashReportFile> reports;
  /// 可展示的受控失败文案。
  final String? errorMessage;
}

/// 崩溃报告管理页允许发送的用户意图。
sealed class CrashReportManagementIntent { const CrashReportManagementIntent(); }
/// 刷新本地报告文件列表。
final class ReloadCrashReportsIntent extends CrashReportManagementIntent { const ReloadCrashReportsIntent(); }
/// 请求上传一份报告。
final class UploadCrashReportIntent extends CrashReportManagementIntent { const UploadCrashReportIntent(this.report); final CrashReportFile report; }
/// 请求查看一份报告。
final class ViewCrashReportIntent extends CrashReportManagementIntent { const ViewCrashReportIntent(this.report); final CrashReportFile report; }
/// 请求通过系统面板分享一份已脱敏报告。
final class ShareCrashReportIntent extends CrashReportManagementIntent { const ShareCrashReportIntent(this.report); final CrashReportFile report; }
/// 请求删除一份报告。
final class DeleteCrashReportIntent extends CrashReportManagementIntent { const DeleteCrashReportIntent(this.report); final CrashReportFile report; }
/// 请求删除全部报告。
final class DeleteAllCrashReportsIntent extends CrashReportManagementIntent { const DeleteAllCrashReportsIntent(); }

/// Route 层处理的一次性副作用。
sealed class CrashReportManagementEffect { const CrashReportManagementEffect(); }
/// 显示短暂受控提示。
final class ShowCrashReportMessageEffect extends CrashReportManagementEffect { const ShowCrashReportMessageEffect(this.message); final String message; }
/// 打开报告只读查看器。
final class ShowCrashReportContentEffect extends CrashReportManagementEffect { const ShowCrashReportContentEffect(this.content); final String content; }
/// 请求 Route 调用系统分享面板。
final class ShareCrashReportEffect extends CrashReportManagementEffect { const ShareCrashReportEffect(this.report); final CrashReportFile report; }
