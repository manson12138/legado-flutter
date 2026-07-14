import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/gateway/bookmark_gateway.dart';
import '../../domain/gateway/reader_cache_gateway.dart';
import '../../domain/gateway/replace_rule_gateway.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/cache.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/model/replace_rule.dart';
import '../dao/bookmark_dao.dart';
import '../dao/cache_dao.dart';
import '../dao/replace_rule_dao.dart';
import '../local/data_error.dart';

/// 组合阅读缓存、书签和替换规则 DAO，实现 M08 阅读数据边界。
final class ReaderRepository
    implements BookmarkGateway, ReplaceRuleGateway, ReaderCacheGateway {
  /// 创建阅读数据 Repository。
  const ReaderRepository(this._cacheDao, this._bookmarkDao, this._replaceRuleDao);

  /// 通用缓存 DAO，用于正文、锚点和显示配置。
  final CacheDao _cacheDao;

  /// 书签 DAO。
  final BookmarkDao _bookmarkDao;

  /// 替换规则 DAO。
  final ReplaceRuleDao _replaceRuleDao;

  /// 观察一本书的书签并统一转换数据库错误。
  @override
  Stream<List<Bookmark>> watchByBook(String bookName, String bookAuthor) {
    return guardDataStream<List<Bookmark>>(
      _bookmarkDao.watchByBook(bookName, bookAuthor),
    );
  }

  /// 保存书签。
  @override
  Future<void> saveBookmark(Bookmark bookmark) {
    return guardDataOperation<void>(() => _bookmarkDao.upsert(bookmark));
  }

  /// 删除书签。
  @override
  Future<void> deleteBookmark(int time) {
    return guardDataOperation<void>(() => _bookmarkDao.deleteByTime(time));
  }

  /// 读取当前书籍生效的正文替换规则。
  @override
  Future<List<ReplaceRule>> getEnabledContentRules(String bookName, String origin) {
    return guardDataOperation<List<ReplaceRule>>(
      () => _replaceRuleDao.getEnabledForContent(bookName, origin),
    );
  }

  /// 读取未过期的章节正文缓存。
  @override
  Future<String?> getChapterContent(String bookUrl, String chapterUrl, int now) {
    return guardDataOperation<String?>(
      () => _cacheDao.getValidValue(_contentKey(bookUrl, chapterUrl), now),
    );
  }

  /// 保存七天有效的原始章节正文缓存。
  @override
  Future<void> saveChapterContent(
    String bookUrl,
    String chapterUrl,
    String content,
    int deadline,
  ) {
    return guardDataOperation<void>(
      () => _cacheDao.upsert(
        Cache(key: _contentKey(bookUrl, chapterUrl), value: content, deadline: deadline),
      ),
    );
  }

  /// 读取稳定正文锚点；损坏的旧缓存按无锚点处理。
  @override
  Future<ReaderPositionAnchor?> getPositionAnchor(String bookUrl) {
    return guardDataOperation<ReaderPositionAnchor?>(() async {
      /// 持久化的锚点 JSON。
      final String? value = await _cacheDao.getValidValue(_anchorKey(bookUrl), DateTime.now().millisecondsSinceEpoch);
      if (value == null || value.isEmpty) {
        return null;
      }
      try {
        /// 收窄后的锚点对象。
        final Object? decoded = jsonDecode(value);
        if (decoded is! Map<String, Object?>) {
          return null;
        }
        /// 章节地址。
        final Object? chapterUrl = decoded['chapterUrl'];
        /// 章节索引。
        final Object? chapterIndex = decoded['chapterIndex'];
        /// 字符位置。
        final Object? characterOffset = decoded['characterOffset'];
        /// 附近正文。
        final Object? context = decoded['context'];
        if (chapterUrl is! String || chapterIndex is! num || characterOffset is! num || context is! String) {
          return null;
        }
        return ReaderPositionAnchor(
          chapterUrl: chapterUrl,
          chapterIndex: chapterIndex.toInt(),
          characterOffset: characterOffset.toInt(),
          context: context,
        );
      } on FormatException {
        return null;
      }
    });
  }

  /// 保存稳定正文锚点，期限为永久。
  @override
  Future<void> savePositionAnchor(String bookUrl, ReaderPositionAnchor anchor) {
    return guardDataOperation<void>(() {
      /// 不含滚动像素的锚点 JSON。
      final String value = jsonEncode(<String, Object?>{
        'chapterUrl': anchor.chapterUrl,
        'chapterIndex': anchor.chapterIndex,
        'characterOffset': anchor.characterOffset,
        'context': anchor.context,
      });
      return _cacheDao.upsert(Cache(key: _anchorKey(bookUrl), value: value));
    });
  }

  /// 读取单书显示配置；无记录或记录损坏时使用跨平台默认值。
  @override
  Future<ReaderDisplayConfig> getDisplayConfig(String bookUrl) {
    return guardDataOperation<ReaderDisplayConfig>(() async {
      /// 持久化的显示配置 JSON。
      final String? value = await _cacheDao.getValidValue(_configKey(bookUrl), DateTime.now().millisecondsSinceEpoch);
      if (value == null || value.isEmpty) {
        return const ReaderDisplayConfig();
      }
      try {
        /// 收窄后的显示配置对象。
        final Object? decoded = jsonDecode(value);
        if (decoded is! Map<String, Object?>) {
          return const ReaderDisplayConfig();
        }
        return ReaderDisplayConfig(
          fontSize: _double(decoded['fontSize'], 18),
          lineHeight: _double(decoded['lineHeight'], 1.7),
          paragraphSpacing: _double(decoded['paragraphSpacing'], 12),
          horizontalPadding: _double(decoded['horizontalPadding'], 20),
          backgroundColorValue: _integer(decoded['backgroundColorValue'], 0xFFFFFBF2),
          textColorValue: _integer(decoded['textColorValue'], 0xFF2B2925),
          useReplaceRules: decoded['useReplaceRules'] is bool ? decoded['useReplaceRules'] as bool : true,
          keepScreenOn: decoded['keepScreenOn'] is bool ? decoded['keepScreenOn'] as bool : true,
        );
      } on FormatException {
        return const ReaderDisplayConfig();
      }
    });
  }

  /// 保存单书显示配置，期限为永久。
  @override
  Future<void> saveDisplayConfig(String bookUrl, ReaderDisplayConfig config) {
    return guardDataOperation<void>(() {
      /// 与 ReaderDisplayConfig 字段一一对应的 JSON。
      final String value = jsonEncode(<String, Object?>{
        'fontSize': config.fontSize,
        'lineHeight': config.lineHeight,
        'paragraphSpacing': config.paragraphSpacing,
        'horizontalPadding': config.horizontalPadding,
        'backgroundColorValue': config.backgroundColorValue,
        'textColorValue': config.textColorValue,
        'useReplaceRules': config.useReplaceRules,
        'keepScreenOn': config.keepScreenOn,
      });
      return _cacheDao.upsert(Cache(key: _configKey(bookUrl), value: value));
    });
  }

  /// 将数字字段收窄为 double，非法类型使用默认值。
  double _double(Object? value, double fallback) {
    return value is num ? value.toDouble() : fallback;
  }

  /// 将数字字段收窄为 int，非法类型使用默认值。
  int _integer(Object? value, int fallback) {
    return value is num ? value.toInt() : fallback;
  }

  /// 生成不泄漏原始 URL 的正文缓存键。
  String _contentKey(String bookUrl, String chapterUrl) {
    return 'reader:content:${_digest('$bookUrl\n$chapterUrl')}';
  }

  /// 生成不泄漏原始 URL 的锚点缓存键。
  String _anchorKey(String bookUrl) => 'reader:anchor:${_digest(bookUrl)}';

  /// 生成不泄漏原始 URL 的显示配置缓存键。
  String _configKey(String bookUrl) => 'reader:config:${_digest(bookUrl)}';

  /// 使用 SHA-256 将不受信任 URL 转换为固定长度缓存键片段。
  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
}
