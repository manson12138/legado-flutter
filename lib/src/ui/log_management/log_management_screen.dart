import 'package:flutter/material.dart';

import '../../help/logging/app_log_manager.dart';
import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'log_management_contract.dart';

/// 单个日志文件弹出菜单支持的操作类型。
enum _LogFileAction {
  /// 打开应用内只读查看器。
  view,

  /// 调用系统分享面板。
  share,

  /// 完整分段回显到 ADB。
  echoToAdb,

  /// 二次确认后删除文件。
  delete,
}

/// 只负责渲染日志状态并发送 Intent 的无状态管理页面。
final class LogManagementScreen extends StatelessWidget {
  /// 创建日志管理纯 UI。
  const LogManagementScreen({
    required this.state,
    required this.onIntent,
    required this.onBack,
    super.key,
  });

  /// ViewModel 提供的当前页面状态。
  final LogManagementUiState state;

  /// 把页面操作发送给 ViewModel 的统一入口。
  final ValueChanged<LogManagementIntent> onIntent;

  /// 返回设置页的导航回调。
  final VoidCallback onBack;

  /// 构建日志列表、刷新入口和全部删除操作。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        title: const Text('管理日志'),
        leading: IconButton(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
        actions: <Widget>[
          IconButton(
            onPressed: () {
              onIntent(const ReloadLogFilesIntent());
            },
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
          IconButton(
            onPressed: state.files.isEmpty
                ? null
                : () {
                    _confirmDeleteAll(context);
                  },
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '删除全部日志',
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  /// 根据加载、错误、空列表和正常列表状态构建页面主体。
  Widget _buildBody(BuildContext context) {
    if (state.isLoading && state.files.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.errorMessage case final String errorMessage
        when state.files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(SpacingToken.large),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: SpacingToken.medium),
              Text(errorMessage, textAlign: TextAlign.center),
              const SizedBox(height: SpacingToken.medium),
              FilledButton.icon(
                onPressed: () {
                  onIntent(const ReloadLogFilesIntent());
                },
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        onIntent(const ReloadLogFilesIntent());
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(SpacingToken.medium),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(SpacingToken.medium),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.info_outline,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: SpacingToken.mediumSmall),
                  const Expanded(
                    child: Text(
                      '日志默认保存在应用私有沙盒。每个文件最多 5 MiB，'
                      '超过后按日期和序号自动创建新文件。',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: SpacingToken.medium),
          if (state.files.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: SpacingToken.xLarge),
              child: Center(child: Text('暂无日志文件')),
            )
          else
            ...state.files.map((AppLogFile file) => _buildFileCard(context, file)),
        ],
      ),
    );
  }

  /// 构建单个日志文件的信息卡和操作菜单。
  Widget _buildFileCard(BuildContext context, AppLogFile file) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: () {
          onIntent(ViewLogFileIntent(file));
        },
        leading: const Icon(Icons.article_outlined),
        title: Text(file.name),
        subtitle: Text(
          '${_formatFileSize(file.sizeBytes)} · ${_formatDateTime(file.modifiedAt)}',
        ),
        trailing: PopupMenuButton<_LogFileAction>(
          tooltip: '日志操作',
          onSelected: (_LogFileAction action) {
            _handleFileAction(context, file, action);
          },
          itemBuilder: (BuildContext context) {
            return const <PopupMenuEntry<_LogFileAction>>[
              PopupMenuItem<_LogFileAction>(
                value: _LogFileAction.view,
                child: ListTile(
                  leading: Icon(Icons.visibility_outlined),
                  title: Text('查看'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<_LogFileAction>(
                value: _LogFileAction.share,
                child: ListTile(
                  leading: Icon(Icons.share_outlined),
                  title: Text('分享'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<_LogFileAction>(
                value: _LogFileAction.echoToAdb,
                child: ListTile(
                  leading: Icon(Icons.terminal_outlined),
                  title: Text('回显到 ADB'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem<_LogFileAction>(
                value: _LogFileAction.delete,
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('删除'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ];
          },
        ),
      ),
    );
  }

  /// 把菜单选择转换成对应 Intent，删除操作会先请求用户确认。
  void _handleFileAction(
    BuildContext context,
    AppLogFile file,
    _LogFileAction action,
  ) {
    switch (action) {
      case _LogFileAction.view:
        onIntent(ViewLogFileIntent(file));
      case _LogFileAction.share:
        onIntent(ShareLogFileIntent(file));
      case _LogFileAction.echoToAdb:
        onIntent(EchoLogFileIntent(file));
      case _LogFileAction.delete:
        _confirmDeleteFile(context, file);
    }
  }

  /// 显示单文件删除确认框，只有明确确认后才发送删除 Intent。
  Future<void> _confirmDeleteFile(BuildContext context, AppLogFile file) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('删除日志'),
          content: Text('确定删除 ${file.name} 吗？此操作无法撤销。'),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(false);
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop(true);
              },
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      onIntent(DeleteLogFileIntent(file));
    }
  }

  /// 显示全部删除确认框，只有明确确认后才发送全部删除 Intent。
  Future<void> _confirmDeleteAll(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('删除全部日志'),
          content: const Text('确定删除全部日志文件吗？此操作无法撤销。'),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(false);
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop(true);
              },
              child: const Text('全部删除'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      onIntent(const DeleteAllLogFilesIntent());
    }
  }

  /// 把字节数格式化为便于用户识别的 B、KiB 或 MiB。
  String _formatFileSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    }
    return '$bytes B';
  }

  /// 把本地修改时间格式化为固定宽度的用户可读文本。
  String _formatDateTime(DateTime value) {
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')} '
        '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}:'
        '${value.second.toString().padLeft(2, '0')}';
  }
}

/// 以可选择、可双向滚动的等宽文本完整展示日志内容。
final class LogViewerPage extends StatelessWidget {
  /// 创建指定文件的只读日志查看器。
  const LogViewerPage({
    required this.file,
    required this.content,
    super.key,
  });

  /// 当前展示的日志文件。
  final AppLogFile file;

  /// 当前日志文件的完整文本内容。
  final String content;

  /// 构建不会截断超长行的只读日志页面。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(title: Text(file.name)),
      body: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(SpacingToken.medium),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectionArea(
              child: Text(
                content.isEmpty ? '<empty>' : content,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
