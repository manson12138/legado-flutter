import 'package:flutter/material.dart';

import '../../help/crash_reporting/crash_report_manager.dart';
import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'crash_report_management_contract.dart';

/// 只渲染状态并发送 Intent 的崩溃报告管理页面。
final class CrashReportManagementScreen extends StatelessWidget {
  /// 创建崩溃报告管理纯 UI。
  const CrashReportManagementScreen({required this.state, required this.onIntent, required this.onBack, super.key});
  /// 当前页面状态。
  final CrashReportManagementUiState state;
  /// 用户操作统一入口。
  final ValueChanged<CrashReportManagementIntent> onIntent;
  /// 返回上一页回调。
  final VoidCallback onBack;

  /// 构建列表和顶部刷新/清空操作。
  @override
  Widget build(BuildContext context) => AppScaffold(
    appBar: AppBar(title: const Text('崩溃日志'), leading: IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back), tooltip: '返回'), actions: <Widget>[
      IconButton(onPressed: () => onIntent(const ReloadCrashReportsIntent()), icon: const Icon(Icons.refresh), tooltip: '刷新'),
      IconButton(onPressed: state.reports.isEmpty ? null : () => _confirmDeleteAll(context), icon: const Icon(Icons.delete_sweep_outlined), tooltip: '清空崩溃日志'),
    ]),
    body: _body(context),
  );

  /// 按加载、错误、空列表或报告列表渲染主体。
  Widget _body(BuildContext context) {
    if (state.isLoading && state.reports.isEmpty) { return const Center(child: CircularProgressIndicator()); }
    if (state.errorMessage case final String message when state.reports.isEmpty) { return Center(child: Text(message)); }
    return RefreshIndicator(
      onRefresh: () async => onIntent(const ReloadCrashReportsIntent()),
      child: ListView(padding: const EdgeInsets.all(SpacingToken.medium), physics: const AlwaysScrollableScrollPhysics(), children: <Widget>[
        const Card(child: Padding(padding: EdgeInsets.all(SpacingToken.medium), child: Text('崩溃日志保存在应用私有目录。上传前已脱敏；上传成功后的状态仅保存在本机，无需进入页面时请求服务器。'))),
        const SizedBox(height: SpacingToken.medium),
        if (state.reports.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: SpacingToken.xLarge), child: Center(child: Text('暂无崩溃日志')))
        else ...state.reports.map((CrashReportFile report) => _card(context, report)),
      ]),
    );
  }

  /// 构建单份报告卡片及查看、上传、删除操作。
  Widget _card(BuildContext context, CrashReportFile report) => Card(child: ListTile(
    leading: Icon(_icon(report.uploadState)),
    title: Text(report.exceptionType, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text('${_date(report.occurredAt)} · ${report.source}\n${_status(report.uploadState)} · ${_size(report.sizeBytes)}'),
    isThreeLine: true,
    onTap: () => onIntent(ViewCrashReportIntent(report)),
    trailing: PopupMenuButton<String>(
      onSelected: (String action) { if (action == 'upload') { onIntent(UploadCrashReportIntent(report)); } if (action == 'share') { onIntent(ShareCrashReportIntent(report)); } if (action == 'delete') { _confirmDelete(context, report); } if (action == 'view') { onIntent(ViewCrashReportIntent(report)); } },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: 'view', child: Text('查看')),
        const PopupMenuItem<String>(value: 'share', child: Text('分享')),
        if (report.uploadState != CrashReportUploadState.uploaded) const PopupMenuItem<String>(value: 'upload', child: Text('上传')),
        const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
      ],
    ),
  ));

  /// 仅在用户确认后请求删除单份报告。
  Future<void> _confirmDelete(BuildContext context, CrashReportFile report) async { if (await _confirm(context, '删除崩溃日志', '确定删除这份崩溃日志吗？此操作无法撤销。') == true) { onIntent(DeleteCrashReportIntent(report)); } }
  /// 仅在用户确认后请求删除全部报告。
  Future<void> _confirmDeleteAll(BuildContext context) async { if (await _confirm(context, '清空崩溃日志', '确定删除全部崩溃日志吗？此操作无法撤销。') == true) { onIntent(const DeleteAllCrashReportsIntent()); } }
  /// 显示可复用的破坏性操作确认框。
  Future<bool?> _confirm(BuildContext context, String title, String content) => showDialog<bool>(context: context, builder: (BuildContext dialogContext) => AlertDialog(title: Text(title), content: Text(content), actions: <Widget>[TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('删除'))]));
  /// 返回状态图标。
  IconData _icon(CrashReportUploadState state) => state == CrashReportUploadState.uploaded ? Icons.cloud_done_outlined : state == CrashReportUploadState.failed ? Icons.cloud_off_outlined : Icons.bug_report_outlined;
  /// 返回用户可读的上传状态。
  String _status(CrashReportUploadState state) => switch (state) { CrashReportUploadState.pending => '未上传', CrashReportUploadState.uploading => '上传中', CrashReportUploadState.uploaded => '已上传', CrashReportUploadState.failed => '上传失败，可重试' };
  /// 格式化文件大小。
  String _size(int bytes) => bytes >= 1024 ? '${(bytes / 1024).toStringAsFixed(1)} KiB' : '$bytes B';
  /// 格式化本地发生时间。
  String _date(DateTime value) => '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
