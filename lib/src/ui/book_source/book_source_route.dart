import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_dependencies.dart';
import '../../domain/model/book_source_import_result.dart';
import '../../help/logging/app_logger.dart';
import '../../platform/book_source_platform_bridge.dart';
import '../theme/app_tokens.dart';
import 'book_source_contract.dart';
import 'book_source_qr_scanner_route.dart';
import 'book_source_screen.dart';
import 'book_source_view_model.dart';

/// 连接书源管理 ViewModel、平台 Effect、对话框和纯 UI 的路由层。
final class BookSourceManagementRoute extends StatefulWidget {
  /// 创建书源管理路由。
  const BookSourceManagementRoute({
    required this.dependencies,
    this.platformBridge = const DefaultBookSourcePlatformBridge(),
    super.key,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 文件和 WebView 登录平台边界。
  final BookSourcePlatformBridge platformBridge;

  /// 创建路由状态。
  @override
  State<BookSourceManagementRoute> createState() => _BookSourceManagementRouteState();
}

/// 持有 ViewModel、Effect 订阅和当前对话框生命周期。
final class _BookSourceManagementRouteState extends State<BookSourceManagementRoute> {
  /// 页面生命周期内唯一 ViewModel。
  late final BookSourceManagementViewModel _viewModel;

  /// 一次性副作用订阅。
  late final StreamSubscription<BookSourceManagementEffect> _effectSubscription;

  /// 当前已交给 Navigator 展示的对话框对象。
  BookSourceDialog? _shownDialog;

  /// 创建 ViewModel 并监听 Effect。
  @override
  void initState() {
    super.initState();
    _viewModel = BookSourceManagementViewModel(
      gateway: widget.dependencies.bookSourceGateway,
      importBookSources: widget.dependencies.importBookSources,
      importTextResolver: widget.dependencies.bookSourceImportTextResolver,
      cancellationTokenFactory: widget.dependencies.createHttpCancellationToken,
      logger: widget.dependencies.logger,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 执行需要 BuildContext 或平台插件的一次性副作用。
  Future<void> _handleEffect(BookSourceManagementEffect effect) async {
    switch (effect) {
      case PickBookSourceFileEffect():
        await _readExternalText(widget.platformBridge.pickSourceText);
      case ReadBookSourceClipboardEffect():
        await _readClipboard();
      case ScanBookSourceQrEffect():
        // 【扫码诊断日志】Route 收到扫码副作用，准备进入相机页面。
        widget.dependencies.logger.debug(
          message: '$bookSourceQrScanLogTag stage=route_effect_received',
        );
        await _scanQrCode();
      case OpenBookSourceLoginEffect(sourceUrl: final String sourceUrl):
        try {
          await widget.platformBridge.openLogin(sourceUrl);
        } catch (error) {
          _showMessage(_platformErrorMessage(error));
        }
      case ShowBookSourceMessageEffect(message: final String message):
        _showMessage(message);
      case CloseBookSourceManagementEffect():
        if (mounted) {
          await Navigator.of(context).maybePop();
        }
    }
  }

  /// 打开相机扫码页面，并把有效结果交给 ViewModel 判断 JSON 或远程书源地址。
  Future<void> _scanQrCode() async {
    if (!mounted) {
      widget.dependencies.logger.warning(
        message: '$bookSourceQrScanLogTag stage=route_open_skipped reason=unmounted',
      );
      return;
    }
    widget.dependencies.logger.info(message: '$bookSourceQrScanLogTag stage=route_opening');
    /// 扫码页面返回的未经信任二维码文本；用户取消时为 null。
    final String? text;
    try {
      text = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (BuildContext context) => BookSourceQrScannerRoute(
            logger: widget.dependencies.logger,
          ),
        ),
      );
    } catch (error, stackTrace) {
      widget.dependencies.logger.error(
        message: '$bookSourceQrScanLogTag stage=flow_finished result=route_error',
        error: error,
        stackTrace: stackTrace,
      );
      _showMessage('打开扫码页面失败');
      return;
    }
    if (text != null && text.trim().isNotEmpty) {
      // 【扫码诊断日志】只记录返回文本长度，不记录二维码原文。
      widget.dependencies.logger.info(
        message: '$bookSourceQrScanLogTag stage=route_result_received chars=${text.length}',
      );
      _viewModel.onIntent(ResolveScannedBookSourceIntent(text));
      return;
    }
    widget.dependencies.logger.info(
      message: '$bookSourceQrScanLogTag stage=flow_finished result=user_cancelled',
    );
  }

  /// 调用文件边界并把结果送入文本导入对话框。
  Future<void> _readExternalText(Future<String?> Function() reader) async {
    try {
      /// 平台返回的外部书源文本。
      final String? text = await reader();
      if (text != null && text.trim().isNotEmpty) {
        _viewModel.onIntent(ShowBookSourceTextImportIntent(initialText: text));
      }
    } catch (error) {
      _showMessage(_platformErrorMessage(error));
    }
  }

  /// 读取系统剪贴板文本。
  Future<void> _readClipboard() async {
    /// 当前剪贴板数据。
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    /// 当前剪贴板文本。
    final String text = data?.text ?? '';
    if (text.trim().isEmpty) {
      _showMessage('剪贴板中没有文本');
      return;
    }
    _viewModel.onIntent(ShowBookSourceTextImportIntent(initialText: text));
  }

  /// 将平台错误转换为不泄漏路径或原始内容的提示。
  String _platformErrorMessage(Object error) {
    if (error is UnsupportedError) {
      return error.message?.toString() ?? '当前平台能力尚未实现';
    }
    if (error is FormatException) {
      return error.message.toString();
    }
    return '读取平台数据失败';
  }

  /// 展示一次性 Snackbar。
  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 根据 UiState 中的业务对话框显示一次 Material 对话框。
  void _syncDialog(BookSourceDialog? dialog) {
    if (dialog == null || identical(dialog, _shownDialog)) {
      return;
    }
    _shownDialog = dialog;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) async {
      if (!mounted || !identical(dialog, _shownDialog)) {
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: !(_viewModel.state.busy),
        builder: (BuildContext context) => _buildDialog(dialog),
      );
      if (identical(dialog, _shownDialog)) {
        _shownDialog = null;
        _viewModel.onIntent(const DismissBookSourceDialogIntent());
      }
    });
  }

  /// 构建与 Contract 对话框类型对应的 UI。
  Widget _buildDialog(BookSourceDialog dialog) {
    return switch (dialog) {
      ImportTextDialog(initialText: final String initialText) => _ImportTextDialogView(
        initialText: initialText,
        onImport: (String text, BookSourceConflictPolicy policy) {
          Navigator.of(context).pop();
          _viewModel.onIntent(
            ImportBookSourceTextIntent(text: text, conflictPolicy: policy),
          );
        },
      ),
      EditBookSourceDialog(draft: final BookSourceEditorDraft draft) => _EditSourceDialogView(
        draft: draft,
        onSave: (BookSourceEditorDraft value) {
          Navigator.of(context).pop();
          _viewModel.onIntent(SaveBookSourceDraftIntent(value));
        },
      ),
      DeleteBookSourcesDialog(sourceUrls: final Set<String> sourceUrls) => AlertDialog(
        title: const Text('确认删除书源'),
        content: Text('将删除 ${sourceUrls.length} 个书源及其搜索缓存，但不会删除书架中的书籍。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _viewModel.onIntent(const ConfirmDeleteBookSourcesIntent());
            },
            child: const Text('删除'),
          ),
        ],
      ),
      SetBookSourceGroupDialog() => _GroupDialogView(
        onSave: (String group) {
          Navigator.of(context).pop();
          _viewModel.onIntent(SaveBookSourceGroupIntent(group));
        },
      ),
      ImportSummaryDialog(result: final BookSourceImportResult result) => _ImportSummaryView(
        result: result,
      ),
      BookSourceDebugDialog(
        sourceName: final String sourceName,
        items: final List<BookSourceDebugItem> items,
      ) => _DebugResultView(sourceName: sourceName, items: items),
    };
  }

  /// 释放 Effect 订阅和 ViewModel。
  @override
  void dispose() {
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 订阅页面状态并连接纯 UI。
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BookSourceManagementUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (BuildContext context, AsyncSnapshot<BookSourceManagementUiState> snapshot) {
        /// 当前可渲染状态。
        final BookSourceManagementUiState state = snapshot.data ?? _viewModel.state;
        _syncDialog(state.dialog);
        return BookSourceManagementScreen(state: state, onIntent: _viewModel.onIntent);
      },
    );
  }
}

/// 文本导入和冲突策略对话框。
final class _ImportTextDialogView extends StatefulWidget {
  /// 创建文本导入对话框。
  const _ImportTextDialogView({required this.initialText, required this.onImport});

  /// 初始 JSON 文本。
  final String initialText;

  /// 确认导入回调。
  final void Function(String text, BookSourceConflictPolicy policy) onImport;

  /// 创建文本导入对话框状态。
  @override
  State<_ImportTextDialogView> createState() => _ImportTextDialogViewState();
}

/// 保存输入控制器和冲突策略选择。
final class _ImportTextDialogViewState extends State<_ImportTextDialogView> {
  /// JSON 多行输入控制器。
  late final TextEditingController _controller;

  /// 当前同 URL 冲突策略。
  BookSourceConflictPolicy _policy = BookSourceConflictPolicy.overwrite;

  /// 初始化 JSON 文本控制器。
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  /// 释放 JSON 文本控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建文本和冲突策略输入界面。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入书源 JSON'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _controller,
                minLines: 8,
                maxLines: 18,
                decoration: const InputDecoration(
                  labelText: 'JSON 对象、数组或转义 JSON 字符串',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: SpacingToken.medium),
              RadioGroup<BookSourceConflictPolicy>(
                groupValue: _policy,
                onChanged: (BookSourceConflictPolicy? value) {
                  if (value != null) {
                    setState(() {
                      _policy = value;
                    });
                  }
                },
                child: const Column(
                  children: <Widget>[
                    RadioListTile<BookSourceConflictPolicy>(
                      value: BookSourceConflictPolicy.overwrite,
                      title: Text('覆盖同 URL 书源'),
                    ),
                    RadioListTile<BookSourceConflictPolicy>(
                      value: BookSourceConflictPolicy.skip,
                      title: Text('跳过同 URL 书源'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            widget.onImport(_controller.text, _policy);
          },
          child: const Text('导入'),
        ),
      ],
    );
  }
}

/// 新增和编辑书源的分组字段表单。
final class _EditSourceDialogView extends StatefulWidget {
  /// 创建编辑对话框。
  const _EditSourceDialogView({required this.draft, required this.onSave});

  /// 初始编辑草稿。
  final BookSourceEditorDraft draft;

  /// 保存草稿回调。
  final ValueChanged<BookSourceEditorDraft> onSave;

  /// 创建书源编辑对话框状态。
  @override
  State<_EditSourceDialogView> createState() => _EditSourceDialogViewState();
}

/// 持有全部文本控制器和开关状态。
final class _EditSourceDialogViewState extends State<_EditSourceDialogView> {
  /// 按字段名保存编辑控制器，值原样保留反斜杠和换行。
  late final Map<String, TextEditingController> _controllers;

  /// 当前启用状态。
  late bool _enabled;

  /// 当前发现启用状态。
  late bool _enabledExplore;

  /// 初始化全部编辑字段控制器。
  @override
  void initState() {
    super.initState();
    /// 初始草稿快捷引用。
    final BookSourceEditorDraft draft = widget.draft;
    _controllers = <String, TextEditingController>{
      'name': TextEditingController(text: draft.name),
      'url': TextEditingController(text: draft.url),
      'group': TextEditingController(text: draft.group),
      'type': TextEditingController(text: draft.type),
      'header': TextEditingController(text: draft.header),
      'searchUrl': TextEditingController(text: draft.searchUrl),
      'exploreUrl': TextEditingController(text: draft.exploreUrl),
      'jsLib': TextEditingController(text: draft.jsLib),
      'ruleSearch': TextEditingController(text: draft.ruleSearch),
      'ruleBookInfo': TextEditingController(text: draft.ruleBookInfo),
      'ruleToc': TextEditingController(text: draft.ruleToc),
      'ruleContent': TextEditingController(text: draft.ruleContent),
      'loginUrl': TextEditingController(text: draft.loginUrl),
      'loginUi': TextEditingController(text: draft.loginUi),
      'loginCheckJs': TextEditingController(text: draft.loginCheckJs),
      'variable': TextEditingController(text: draft.variable),
      'comment': TextEditingController(text: draft.comment),
    };
    _enabled = draft.enabled;
    _enabledExplore = draft.enabledExplore;
  }

  /// 释放全部编辑字段控制器。
  @override
  void dispose() {
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 构建分组后的书源字段编辑器。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.draft.originalUrl.isEmpty ? '新增书源' : '编辑书源'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _field('name', '名称', requiredField: true),
              _field('url', 'URL（修改后按新主键保存）', requiredField: true),
              Row(
                children: <Widget>[
                  Expanded(child: _field('group', '分组')),
                  const SizedBox(width: SpacingToken.small),
                  SizedBox(width: 120, child: _field('type', '类型 0～4')),
                ],
              ),
              SwitchListTile(
                value: _enabled,
                title: const Text('启用搜索'),
                onChanged: (bool value) {
                  setState(() {
                    _enabled = value;
                  });
                },
              ),
              SwitchListTile(
                value: _enabledExplore,
                title: const Text('启用发现'),
                onChanged: (bool value) {
                  setState(() {
                    _enabledExplore = value;
                  });
                },
              ),
              _section('请求与入口'),
              _field('header', 'Header', lines: 4),
              _field('searchUrl', '搜索 URL/脚本', lines: 4),
              _field('exploreUrl', '发现 URL/脚本', lines: 4),
              _section('规则与 JavaScript'),
              _field('jsLib', 'jsLib', lines: 6),
              _field('ruleSearch', '搜索规则', lines: 6),
              _field('ruleBookInfo', '详情规则', lines: 6),
              _field('ruleToc', '目录规则', lines: 6),
              _field('ruleContent', '正文规则', lines: 6),
              _section('登录与说明'),
              _field('loginUrl', '登录 URL'),
              _field('loginUi', '登录 UI', lines: 4),
              _field('loginCheckJs', '登录检测 JS', lines: 5),
              _field('variable', '书源变量（source.getVariable）', lines: 4),
              _field('comment', '书源说明', lines: 3),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  /// 创建分区标题。
  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: SpacingToken.medium, bottom: SpacingToken.small),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }

  /// 创建保持原始文本的编辑字段。
  Widget _field(String key, String label, {int lines = 1, bool requiredField = false}) {
    /// 字段对应控制器。
    final TextEditingController? controller = _controllers[key];
    return Padding(
      padding: const EdgeInsets.only(bottom: SpacingToken.small),
      child: TextField(
        controller: controller,
        minLines: lines,
        maxLines: lines,
        decoration: InputDecoration(
          labelText: requiredField ? '$label *' : label,
          border: const OutlineInputBorder(),
          alignLabelWithHint: lines > 1,
        ),
      ),
    );
  }

  /// 从控制器构建完整草稿并提交给 ViewModel。
  void _save() {
    /// 安全读取指定字段文本。
    String text(String key) => _controllers[key]?.text ?? '';
    widget.onSave(
      BookSourceEditorDraft(
        originalUrl: widget.draft.originalUrl,
        name: text('name'),
        url: text('url'),
        group: text('group'),
        type: text('type'),
        enabled: _enabled,
        enabledExplore: _enabledExplore,
        header: text('header'),
        searchUrl: text('searchUrl'),
        exploreUrl: text('exploreUrl'),
        jsLib: text('jsLib'),
        ruleSearch: text('ruleSearch'),
        ruleBookInfo: text('ruleBookInfo'),
        ruleToc: text('ruleToc'),
        ruleContent: text('ruleContent'),
        loginUrl: text('loginUrl'),
        loginUi: text('loginUi'),
        loginCheckJs: text('loginCheckJs'),
        variable: text('variable'),
        comment: text('comment'),
      ),
    );
  }
}

/// 批量分组输入对话框。
final class _GroupDialogView extends StatefulWidget {
  /// 创建分组对话框。
  const _GroupDialogView({required this.onSave});

  /// 保存分组回调。
  final ValueChanged<String> onSave;

  /// 创建分组对话框状态。
  @override
  State<_GroupDialogView> createState() => _GroupDialogViewState();
}

/// 持有分组文本控制器。
final class _GroupDialogViewState extends State<_GroupDialogView> {
  /// 分组输入控制器。
  final TextEditingController _controller = TextEditingController();

  /// 释放分组输入控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建分组输入界面。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置分组'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          labelText: '逗号分隔；留空表示清除分组',
          border: OutlineInputBorder(),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            widget.onSave(_controller.text);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 导入统计结果对话框。
final class _ImportSummaryView extends StatelessWidget {
  /// 创建导入摘要。
  const _ImportSummaryView({required this.result});

  /// 导入统计结果。
  final BookSourceImportResult result;

  /// 构建导入统计和失败详情。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入结果'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('总数：${result.total}'),
            Text('新增：${result.added}'),
            Text('覆盖：${result.overwritten}'),
            Text('跳过：${result.skipped}'),
            Text('无效：${result.invalid}'),
            if (result.issues.isNotEmpty) ...<Widget>[
              const SizedBox(height: SpacingToken.medium),
              const Text('失败详情：'),
              ...result.issues.take(20).map(
                (BookSourceImportIssue issue) => Text('第 ${issue.index + 1} 条：${issue.message}'),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('完成')),
      ],
    );
  }
}

/// 基础调试分类结果对话框。
final class _DebugResultView extends StatelessWidget {
  /// 创建调试结果视图。
  const _DebugResultView({required this.sourceName, required this.items});

  /// 书源名称。
  final String sourceName;

  /// 分类调试项。
  final List<BookSourceDebugItem> items;

  /// 构建网络、规则和 JavaScript 分类结果。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('基础调试：$sourceName'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: items.map((BookSourceDebugItem item) {
            return ListTile(
              leading: Icon(
                item.isError ? Icons.error_outline : Icons.check_circle_outline,
                color: item.isError ? Theme.of(context).colorScheme.error : null,
              ),
              title: Text(item.category),
              subtitle: Text(item.message),
            );
          }).toList(growable: false),
        ),
      ),
      actions: <Widget>[
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
      ],
    );
  }
}
