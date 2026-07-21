import 'package:flutter/material.dart';

import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'about_contract.dart';

/// 只负责渲染“关于”状态并发送 Intent 的无状态页面。
final class AboutScreen extends StatelessWidget {
  /// 创建“关于”页纯 UI。
  const AboutScreen({
    required this.state,
    required this.onIntent,
    required this.onBack,
    super.key,
  });

  /// ViewModel 提供的当前页面状态。
  final AboutUiState state;

  /// 把页面操作发送给 ViewModel 的统一入口。
  final ValueChanged<AboutIntent> onIntent;

  /// 返回“我的”页面的导航回调。
  final VoidCallback onBack;

  /// 构建应用信息、数据边界说明和解锁后的内容过滤管理入口。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        title: const Text('关于'),
        leading: IconButton(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(SpacingToken.large),
        children: <Widget>[
          const SizedBox(height: SpacingToken.large),
          Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(RadiusToken.large),
              onTap: () => onIntent(const TapAppIconIntent()),
              child: Padding(
                padding: const EdgeInsets.all(SpacingToken.medium),
                child: Icon(
                  Icons.auto_stories,
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: SpacingToken.medium),
          const Center(
            child: Text('Legado Flutter', style: TextStyle(fontSize: 20)),
          ),
          const SizedBox(height: SpacingToken.xSmall),
          Center(
            child: Text(
              '1.0.0+5',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: SpacingToken.large),
          const Text('Android 与 iOS 共用的简约阅读客户端。书架、书源和阅读数据默认保存在本机。'),
          if (state.contentFilterUnlocked) ...<Widget>[
            const SizedBox(height: SpacingToken.large),
            const Text('内容过滤管理', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: SpacingToken.small),
            _ContentFilterCard(state: state, onIntent: onIntent),
          ],
        ],
      ),
    );
  }
}

/// 展示成人内容屏蔽开关、生效词库数量和远程更新入口。
final class _ContentFilterCard extends StatelessWidget {
  /// 创建内容过滤管理卡片。
  const _ContentFilterCard({required this.state, required this.onIntent});

  /// 当前页面状态。
  final AboutUiState state;

  /// 把页面操作发送给 ViewModel 的统一入口。
  final ValueChanged<AboutIntent> onIntent;

  /// 构建开关和更新词库按钮。
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(RadiusToken.medium),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpacingToken.small,
          vertical: SpacingToken.xSmall,
        ),
        child: Column(
          children: <Widget>[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('屏蔽成人内容'),
              subtitle: Text('当前词库 ${state.adultKeywordCount} 条；覆盖书源导入、搜索结果和换源候选'),
              value: state.blockAdultContent,
              onChanged: (bool value) {
                onIntent(ToggleBlockAdultContentIntent(value));
              },
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(bottom: SpacingToken.xSmall),
                child: TextButton(
                  onPressed: state.updatingAdultKeywords
                      ? null
                      : () => onIntent(const UpdateAdultKeywordsIntent()),
                  child: Text(state.updatingAdultKeywords ? '更新中…' : '更新词库'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
