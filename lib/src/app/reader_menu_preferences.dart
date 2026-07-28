import '../data/local/preferences/app_preferences_store.dart';

/// 管理阅读器顶部与底部工具栏在当前 App 安装周期内的一次性自动展示状态。
///
/// 该状态是设备级视觉提示，不按书籍或账号隔离；覆盖安装、登录、退出登录和账号切换
/// 都保留已展示状态，只有卸载 App、清除应用数据或以后显式升级键版本才重新展示。
/// 存储内容只有一个布尔值，不包含书籍、账号、阅读进度或其他隐私数据。
final class ReaderMenuPreferences {
  /// 创建阅读器工具栏一次性展示偏好服务。
  ReaderMenuPreferences(this._preferencesStore);

  /// 工具栏自动展示状态的设备级稳定键；v1 没有旧持久化来源需要迁移。
  static const String _autoShownKey =
      'reader.menu_auto_shown.v1.device';

  /// MMKV 或初始化失败时的进程内降级存储。
  final AppPreferencesStore _preferencesStore;

  /// 当前进程是否已经把自动展示资格交给某个阅读路由，避免快速重复导航重复领取。
  bool _claimedInProcess = false;

  /// 判断当前阅读路由是否应自动显示一次顶部和底部工具栏。
  ///
  /// 键不存在、类型损坏或首次升级到该版本时按“尚未展示”处理；领取资格后先在
  /// 进程内锁定，真正渲染出工具栏后再由 [markShown] 提交持久化状态。
  bool claimInitialVisibility() {
    if (_claimedInProcess) {
      return false;
    }
    _claimedInProcess = true;
    return !(_preferencesStore.readBool(_autoShownKey) ?? false);
  }

  /// 在阅读正文和工具栏已经实际进入可见帧后记录本安装周期已自动展示。
  void markShown() {
    if (!_preferencesStore.writeBool(_autoShownKey, true)) {
      throw StateError('阅读器工具栏自动展示状态写入失败');
    }
  }
}
