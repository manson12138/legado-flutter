import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cross_file/cross_file.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_dependencies.dart';
import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'crash_report_management_contract.dart';
import 'crash_report_management_screen.dart';
import 'crash_report_management_view_model.dart';

/// 连接崩溃报告 ViewModel、路由生命周期与只读查看器。
final class CrashReportManagementRoute extends StatefulWidget {
  /// 创建由组合根注入依赖的报告管理路由。
  const CrashReportManagementRoute({required this.dependencies, super.key});
  /// 应用共享依赖。
  final AppDependencies dependencies;
  /// 创建路由 State。
  @override State<CrashReportManagementRoute> createState() => _CrashReportManagementRouteState();
}

/// 管理页面订阅，防止路由销毁后继续更新 UI。
final class _CrashReportManagementRouteState extends State<CrashReportManagementRoute> {
  /// 页面唯一 ViewModel。
  late final CrashReportManagementViewModel _viewModel;
  /// 状态订阅。
  late final StreamSubscription<CrashReportManagementUiState> _stateSubscription;
  /// 副作用订阅。
  late final StreamSubscription<CrashReportManagementEffect> _effectSubscription;
  /// 当前渲染状态。
  late CrashReportManagementUiState _state;
  /// 创建 ViewModel 和流订阅。
  @override void initState() { super.initState(); _viewModel = CrashReportManagementViewModel(manager: widget.dependencies.crashReportManager); _state = _viewModel.state; _stateSubscription = _viewModel.states.listen((CrashReportManagementUiState state) { if (mounted) { setState(() { _state = state; }); } }); _effectSubscription = _viewModel.effects.listen(_effect); }
  /// 把副作用转为 Snackbar 或只读内容页面。
  void _effect(CrashReportManagementEffect effect) { if (!mounted) { return; } switch (effect) { case ShowCrashReportMessageEffect(message: final String message): ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(message))); case ShowCrashReportContentEffect(content: final String content): Navigator.of(context).push(MaterialPageRoute<void>(builder: (BuildContext context) => _CrashReportViewer(content: content))); case ShareCrashReportEffect(report: final report): unawaited(_share(report.path)); } }
  /// 调用系统面板分享已脱敏的单个 JSON 报告。
  Future<void> _share(String path) async { try { await SharePlus.instance.share(ShareParams(files: <XFile>[XFile(path, mimeType: 'application/json')], title: 'Legado Flutter 崩溃日志')); } on Object { if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('分享崩溃日志失败。'))); } } }
  /// 释放订阅和 ViewModel 资源。
  @override void dispose() { _stateSubscription.cancel(); _effectSubscription.cancel(); _viewModel.dispose(); super.dispose(); }
  /// 将状态和意图传入纯 UI。
  @override Widget build(BuildContext context) => CrashReportManagementScreen(state: _state, onIntent: _viewModel.onIntent, onBack: () => Navigator.of(context).pop());
}

/// 展示已脱敏 JSON 的只读页面。
final class _CrashReportViewer extends StatelessWidget {
  /// 创建报告内容查看器。
  const _CrashReportViewer({required this.content});
  /// 已脱敏且格式化的 JSON 文本。
  final String content;
  /// 构建可选择、可滚动的等宽内容。
  @override Widget build(BuildContext context) => AppScaffold(appBar: AppBar(title: const Text('崩溃日志详情')), body: SingleChildScrollView(padding: const EdgeInsets.all(SpacingToken.medium), child: SelectionArea(child: Text(content, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)))));
}
