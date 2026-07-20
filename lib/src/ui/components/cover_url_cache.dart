import 'dart:async';

import '../../domain/gateway/cover_cache_gateway.dart';

/// 跨页面、跨应用重启共享的“已知可显示封面地址”缓存。
///
/// 键使用书名 + 作者，和搜索候选分组、书签等既有“同一本书”判定口径保持一致——单用
/// 书名容易在不同作者的同名书之间互相顶替封面，必须搭配作者一起做 key。
///
/// [BookCover] 深埋在书架、搜索结果和详情等无状态 Screen 里，这些 Screen 按 MVI 约定
/// 不持有 `AppDependencies`/Gateway，所以本类保持全局单例访问，只由 [AppDependencies]
/// 在组合根用 [configure] 接入一次真正的持久化实现；调用前后 [lookup] 都不会抛异常，
/// 未配置时等价于缓存永远未命中，不影响封面正常展示或占位兜底。
///
/// 数据最终落在通用缓存表（`deadline = 0` 永久保存），进程内额外维护一层内存读穿
/// 缓存，避免同一本书每次渲染都打一次数据库。
final class CoverUrlCache {
  CoverUrlCache._();

  /// 全局唯一实例。
  static final CoverUrlCache instance = CoverUrlCache._();

  /// 持久化实现；组合根调用 [configure] 前为 null。
  CoverCacheGateway? _gateway;

  /// 按 `书名|作者` 保存的最近一次成功加载地址，命中过一次后不用再查数据库。
  final Map<String, String> _memory = <String, String>{};

  /// 由组合根注入真正的持久化实现；应用生命周期内只调用一次。
  void configure(CoverCacheGateway gateway) {
    _gateway = gateway;
  }

  /// 生成稳定缓存键；书名和作者都先去除首尾空白，避免格式差异导致命中失败。
  String _key(String name, String author) => '${name.trim()}|${author.trim()}';

  /// 查找同一本书之前在任意页面成功显示过的封面地址；先查内存，未命中再查数据库。
  Future<String?> lookup({required String name, required String author}) async {
    if (name.trim().isEmpty) {
      return null;
    }
    /// 稳定缓存键。
    final String key = _key(name, author);
    /// 内存里已知的地址。
    final String? cached = _memory[key];
    if (cached != null) {
      return cached;
    }
    final CoverCacheGateway? gateway = _gateway;
    if (gateway == null) {
      return null;
    }
    try {
      /// 数据库里已知的地址。
      final String? stored = await gateway.getCoverUrl(name, author);
      if (stored != null && stored.isNotEmpty) {
        _memory[key] = stored;
        return stored;
      }
      return null;
    } on Object {
      /// 数据库读取失败按未命中处理，不影响封面正常展示或占位兜底。
      return null;
    }
  }

  /// 记录一次成功加载的封面地址：立即更新内存，再异步写入数据库并永久保存。
  void remember({required String name, required String author, required String url}) {
    /// 清理后的地址。
    final String trimmedUrl = url.trim();
    if (name.trim().isEmpty || trimmedUrl.isEmpty) {
      return;
    }
    _memory[_key(name, author)] = trimmedUrl;
    final CoverCacheGateway? gateway = _gateway;
    if (gateway == null) {
      return;
    }
    unawaited(gateway.saveCoverUrl(name, author, trimmedUrl).catchError((Object _) {}));
  }
}
