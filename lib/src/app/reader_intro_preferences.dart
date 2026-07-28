import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/local/preferences/app_preferences_store.dart';

/// 按当前用户和书籍记录首次阅读先导页是否已经真正进入过正文。
///
/// 只保存不可逆书籍摘要和布尔值，不保存原始书籍 URL、正文或阅读进度。
final class ReaderIntroPreferences {
  /// 创建首次阅读先导页偏好服务。
  const ReaderIntroPreferences(
    this._preferencesStore,
    this._requireUserId,
  );

  /// MMKV 或其进程内降级实现。
  final AppPreferencesStore _preferencesStore;

  /// 获取当前游客或登录账号的稳定本地作用域 ID。
  final int Function() _requireUserId;

  /// 判断当前用户是否已经实际进入过这本书的正文。
  bool hasSeen(String bookUrl) {
    return _preferencesStore.readBool(_key(bookUrl)) ?? false;
  }

  /// 在正文首次真正可见后记录先导页完成状态。
  void markSeen(String bookUrl) {
    if (!_preferencesStore.writeBool(_key(bookUrl), true)) {
      throw StateError('阅读先导页状态写入失败');
    }
  }

  /// 清除当前用户指定书籍的先导页完成状态。
  void clear(String bookUrl) {
    _preferencesStore.remove(_key(bookUrl));
  }

  /// 生成不暴露原始 URL 的用户级 MMKV 键。
  String _key(String bookUrl) {
    final int userId = _requireUserId();
    final String digest = sha256.convert(utf8.encode(bookUrl)).toString();
    return 'reader.intro_seen.v1.user.$userId.book.$digest';
  }
}
