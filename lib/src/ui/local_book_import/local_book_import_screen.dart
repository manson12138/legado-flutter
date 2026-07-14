import 'package:flutter/material.dart';

import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'local_book_import_contract.dart';

/// 只渲染导入状态并发送 Intent 的无状态页面。
final class LocalBookImportScreen extends StatelessWidget {
  /// 创建本地书导入纯 UI。
  const LocalBookImportScreen({required this.state, required this.onIntent, super.key});

  /// ViewModel 提供的完整页面状态。
  final LocalBookImportUiState state;

  /// 页面用户操作统一入口。
  final ValueChanged<LocalBookImportIntent> onIntent;

  /// 构建文件选择、批量控制、进度和候选列表。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: state.busy ? null : () => onIntent(const CloseLocalBookImportIntent()),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
        title: const Text('导入本地书'),
        actions: <Widget>[
          IconButton(
            onPressed: state.busy ? null : () => onIntent(const PickLocalBooksIntent()),
            icon: const Icon(Icons.add_to_photos_outlined),
            tooltip: '重新选择文件',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _ImportHeader(state: state, onIntent: onIntent),
          if (state.busy) _ImportProgress(state: state),
          Expanded(child: _ImportBody(state: state, onIntent: onIntent)),
        ],
      ),
    );
  }
}

/// 展示选择统计、全选和批量导入动作。
final class _ImportHeader extends StatelessWidget {
  /// 创建导入控制区。
  const _ImportHeader({required this.state, required this.onIntent});

  /// 当前页面状态。
  final LocalBookImportUiState state;

  /// 用户操作入口。
  final ValueChanged<LocalBookImportIntent> onIntent;

  /// 构建顶部控制卡片。
  @override
  Widget build(BuildContext context) {
    /// 是否全部候选项均已选中。
    final bool allSelected = state.items.isNotEmpty && state.selectedCount == state.items.length;
    return Padding(
      padding: const EdgeInsets.all(SpacingToken.medium),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(SpacingToken.medium),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                state.items.isEmpty
                    ? '请选择 TXT 或 EPUB 文件。其他 Android 基线格式会给出明确支持状态。'
                    : '已选择 ${state.selectedCount}/${state.items.length} 个文件',
              ),
              const SizedBox(height: SpacingToken.small),
              Wrap(
                spacing: SpacingToken.small,
                runSpacing: SpacingToken.small,
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: state.busy ? null : () => onIntent(const PickLocalBooksIntent()),
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('选择文件'),
                  ),
                  OutlinedButton.icon(
                    onPressed: state.busy || state.items.isEmpty
                        ? null
                        : () => onIntent(SetAllLocalBooksSelectedIntent(!allSelected)),
                    icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
                    label: Text(allSelected ? '取消全选' : '全选'),
                  ),
                  FilledButton.icon(
                    onPressed: state.busy || state.selectedCount == 0
                        ? null
                        : () => onIntent(const ImportSelectedLocalBooksIntent()),
                    icon: const Icon(Icons.library_add_outlined),
                    label: const Text('加入书架'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 展示当前批次有界进度。
final class _ImportProgress extends StatelessWidget {
  /// 创建导入进度区。
  const _ImportProgress({required this.state});

  /// 当前导入状态。
  final LocalBookImportUiState state;

  /// 构建进度条和完成数量。
  @override
  Widget build(BuildContext context) {
    /// 当前有界进度；总数为零时使用不确定进度。
    final double? value = state.total == 0 ? null : state.completed / state.total;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LinearProgressIndicator(value: value),
          const SizedBox(height: SpacingToken.small),
          Text('正在复制、解析并写入书架：${state.completed}/${state.total}'),
        ],
      ),
    );
  }
}

/// 展示空状态或文件候选列表。
final class _ImportBody extends StatelessWidget {
  /// 创建候选列表主体。
  const _ImportBody({required this.state, required this.onIntent});

  /// 当前页面状态。
  final LocalBookImportUiState state;

  /// 用户操作入口。
  final ValueChanged<LocalBookImportIntent> onIntent;

  /// 构建空状态或惰性列表。
  @override
  Widget build(BuildContext context) {
    if (state.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(SpacingToken.xLarge),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.menu_book_outlined, size: 64),
              const SizedBox(height: SpacingToken.medium),
              const Text('还没有选择本地书'),
              const SizedBox(height: SpacingToken.medium),
              FilledButton(
                onPressed: () => onIntent(const PickLocalBooksIntent()),
                child: const Text('选择文件'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        SpacingToken.medium,
        0,
        SpacingToken.medium,
        SpacingToken.large,
      ),
      itemCount: state.items.length,
      separatorBuilder: (BuildContext context, int index) => const SizedBox(height: SpacingToken.small),
      itemBuilder: (BuildContext context, int index) {
        /// 当前索引候选项。
        final LocalBookImportItem item = state.items[index];
        return Card(
          child: CheckboxListTile(
            value: item.selected,
            onChanged: state.busy ? null : (bool? value) => onIntent(ToggleLocalBookSelectionIntent(index)),
            secondary: Icon(_statusIcon(item.status), color: _statusColor(context, item.status)),
            title: Text(item.file.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${_formatBytes(item.file.size)}${item.message == null ? '' : '\n${item.message}'}',
            ),
            isThreeLine: item.message != null,
          ),
        );
      },
    );
  }

  /// 返回导入状态对应图标。
  IconData _statusIcon(LocalBookImportItemStatus status) {
    return switch (status) {
      LocalBookImportItemStatus.pending => Icons.description_outlined,
      LocalBookImportItemStatus.importing => Icons.hourglass_top,
      LocalBookImportItemStatus.imported => Icons.check_circle_outline,
      LocalBookImportItemStatus.updated => Icons.update,
      LocalBookImportItemStatus.failed => Icons.error_outline,
    };
  }

  /// 返回导入状态对应主题颜色。
  Color? _statusColor(BuildContext context, LocalBookImportItemStatus status) {
    return switch (status) {
      LocalBookImportItemStatus.failed => Theme.of(context).colorScheme.error,
      LocalBookImportItemStatus.imported || LocalBookImportItemStatus.updated => Theme.of(context).colorScheme.primary,
      _ => null,
    };
  }

  /// 将字节数转换为紧凑的人类可读文本。
  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}
