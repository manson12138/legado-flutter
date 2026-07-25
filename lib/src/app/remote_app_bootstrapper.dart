import '../api/remote_app/remote_app_api.dart';
import '../data/repository/remote_app_configuration_repository.dart';
import '../domain/gateway/adult_content_gateway.dart';
import '../help/logging/app_logger.dart';

/// 应用显示后异步刷新远端启动配置和内容过滤规则；失败时不阻断本地阅读。
final class RemoteAppBootstrapper {
  /// 创建远端启动协调器。
  RemoteAppBootstrapper({required RemoteAppConfigurationRepository repository, required AdultContentGateway adultContentGateway, required AppLogger logger})
      : _repository = repository,
        _adultContentGateway = adultContentGateway,
        _logger = logger;

  /// 远端配置仓储。
  final RemoteAppConfigurationRepository _repository;
  /// 已有内容过滤边界。
  final AdultContentGateway _adultContentGateway;
  /// 应用日志。
  final AppLogger _logger;

  /// 后台刷新服务端配置，网络或数据异常时保留本地规则。
  Future<RemoteAppBootstrapStatus?> refreshInBackground() async {
    _logger.info(tag: appStartupLogTag, message: 'stage=bootstrap_started');
    RemoteAppBootstrapStatus status;
    try {
      status = await _repository.refreshBootstrapStatus();
    } catch (error) {
      _logger.warning(tag: appStartupLogTag, message: 'stage=bootstrap_degraded reason=remote_unavailable', error: error);
      return null;
    }
    try {
      final List<Map<String, Object?>> values = await Future.wait(<Future<Map<String, Object?>>>[_repository.refreshKeywords(), _repository.refreshDomains()]);
      final Set<String> keywords = _readRules(values[0], 'word');
      final Set<String> domains = _readRules(values[1], 'domain');
      await _adultContentGateway.replaceRemoteRules(keywords: keywords, domains: domains);
      _logger.info(tag: appStartupLogTag, message: 'stage=bootstrap_refreshed keywords=${keywords.length} domains=${domains.length}');
    } catch (error) {
      _logger.warning(tag: appStartupLogTag, message: 'stage=filter_degraded reason=remote_unavailable', error: error);
    }
    return status;
  }

  /// 从 `{version,items}` 中提取启用规则值。
  Set<String> _readRules(Map<String, Object?> value, String field) {
    final Object? items = value['items'];
    if (items is! List<Object?>) { throw const FormatException('远端过滤规则缺少列表'); }
    return items.whereType<Map<Object?, Object?>>().where((Map<Object?, Object?> item) => item['enabled'] == true).map((Map<Object?, Object?> item) => item[field]).whereType<String>().map((String item) => item.trim()).where((String item) => item.isNotEmpty).toSet();
  }
}
