import 'package:flutter/material.dart';

import '../../app/app_access_coordinator.dart';
import '../../api/remote_app/remote_app_service_config.dart';
import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'about_contract.dart';

/// 只负责渲染“关于”状态并发送 Intent 的无状态页面。
final class AboutScreen extends StatelessWidget {
  /// 创建“关于”页纯 UI。
  const AboutScreen({
    required this.state,
    required this.appAccessState,
    required this.appVersionName,
    required this.appVersionCode,
    required this.onIntent,
    required this.onCheckUpdate,
    required this.onBack,
    super.key,
  });

  /// ViewModel 提供的当前页面状态。
  final AboutUiState state;

  /// 应用级准入协调器提供的最新版本状态。
  final AppAccessState appAccessState;

  /// 当前安装包的真实版本名称。
  final String appVersionName;

  /// 当前安装包的真实构建号。
  final int appVersionCode;

  /// 把页面操作发送给 ViewModel 的统一入口。
  final ValueChanged<AboutIntent> onIntent;

  /// 用户手动请求重新检查服务端版本状态的回调。
  final VoidCallback onCheckUpdate;

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
            child: Text('PageNest（拾页）', style: TextStyle(fontSize: 20)),
          ),
          const SizedBox(height: SpacingToken.xSmall),
          Center(
            child: Text(
              '$appVersionName+$appVersionCode',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: SpacingToken.large),
          const Text('Android 与 iOS 共用的简约阅读客户端。书架、书源和阅读数据默认保存在本机。'),
          const SizedBox(height: SpacingToken.large),
          _AppUpdateCard(
            state: appAccessState,
            onCheckUpdate: onCheckUpdate,
          ),
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

/// 展示当前版本检查状态，并提供手动检查入口。
final class _AppUpdateCard extends StatelessWidget {
  /// 创建应用版本检查卡片。
  const _AppUpdateCard({
    required this.state,
    required this.onCheckUpdate,
  });

  /// 应用级准入协调器的受控状态。
  final AppAccessState state;

  /// 触发一次前台单飞版本检查的回调。
  final VoidCallback onCheckUpdate;

  /// 构建版本状态说明与检查按钮。
  @override
  Widget build(BuildContext context) {
    final bool checking = state.isRestoring || state.isChecking;
    final bool latest = state.hasConfirmedStatus && !state.hasUpdate;
    final String versionName = state.versionName?.trim() ?? '';
    final String statusText = checking
        ? '正在检查更新…'
        : latest
        ? '已是最新版本'
        : state.hasConfirmedStatus
        ? '发现新版本${versionName.isEmpty ? '' : ' $versionName'}'
        : '尚未检查更新';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RadiusToken.medium),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(
            alpha: 0.55,
          ),
        ),
      ),
      child: ListTile(
        leading: Icon(
          latest ? Icons.verified_outlined : Icons.system_update_outlined,
          color: latest ? Theme.of(context).colorScheme.primary : null,
        ),
        title: const Text('版本更新'),
        subtitle: Text(statusText),
        trailing: checking
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : latest
            ? const Icon(Icons.check_circle_outline)
            : TextButton(
                onPressed: onCheckUpdate,
                child: const Text('检查更新'),
              ),
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

  /// 当前安装包实际用于 App HMAC 签名的编译期密钥；仅在连点解锁的排查入口展示，
  /// 便于与服务端的 `APP_SIGNATURE_SECRET` 逐字核对。
  static final String _appSignatureSecret =
      RemoteAppServiceConfig.fromEnvironment().hmacSecret;

  /// 构建开关和更新词库按钮。
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RadiusToken.medium),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      clipBehavior: Clip.antiAlias,
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
            const Divider(height: SpacingToken.small),
            Padding(
              padding: const EdgeInsets.only(
                left: SpacingToken.small,
                right: SpacingToken.small,
                bottom: SpacingToken.small,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '当前 App 签名密钥（对应服务端 APP_SIGNATURE_SECRET）',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: SpacingToken.xSmall),
                    SelectableText(
                      _appSignatureSecret,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
