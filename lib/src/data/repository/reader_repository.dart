import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/gateway/bookmark_gateway.dart';
import '../../domain/gateway/cover_cache_gateway.dart';
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
    implements BookmarkGateway, ReplaceRuleGateway, ReaderCacheGateway, CoverCacheGateway {
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
        /// 当前覆盖翻页默认值迁移版本；旧缓存无此字段时统一迁移一次。
        final int horizontalCoverDefaultVersion = _integer(
          decoded['horizontalCoverDefaultVersion'],
          0,
        );
        /// 是否已经执行“左右分页 + 覆盖翻页”的默认值迁移。
        final bool hasHorizontalCoverDefault = horizontalCoverDefaultVersion >= 1;
        return ReaderDisplayConfig(
          fontSize: _double(decoded['fontSize'], 18),
          lineHeight: _double(decoded['lineHeight'], 1.7),
          paragraphSpacing: _double(decoded['paragraphSpacing'], 12),
          horizontalPadding: _double(decoded['horizontalPadding'], 20),
          verticalPadding: _double(decoded['verticalPadding'], 20),
          letterSpacing: _double(decoded['letterSpacing'], 0),
          fontWeightValue: _fontWeightValue(decoded['fontWeightValue']),
          textItalic: decoded['textItalic'] is bool ? decoded['textItalic'] as bool : false,
          backgroundColorValue: _integer(decoded['backgroundColorValue'], 0xFFFFFBF2),
          textColorValue: _integer(decoded['textColorValue'], 0xFF2B2925),
          useReplaceRules: decoded['useReplaceRules'] is bool ? decoded['useReplaceRules'] as bool : true,
          keepScreenOn: decoded['keepScreenOn'] is bool ? decoded['keepScreenOn'] as bool : true,
          preDownloadCount: _preDownloadCount(decoded['preDownloadCount']),
          readingMode: hasHorizontalCoverDefault
              ? _readingMode(decoded['readingMode'])
              : ReaderReadingMode.horizontalPaging,
          pageTurnStyle: hasHorizontalCoverDefault
              ? _pageTurnStyle(decoded['pageTurnStyle'])
              : ReaderPageTurnStyle.cover,
          showHeaderFooter: decoded['showHeaderFooter'] is bool
              ? decoded['showHeaderFooter'] as bool
              : true,
          showMenuToolLabels: decoded['showMenuToolLabels'] is bool
              ? decoded['showMenuToolLabels'] as bool
              : true,
          textShadow: decoded['textShadow'] is bool ? decoded['textShadow'] as bool : false,
          textUnderline: decoded['textUnderline'] is bool
              ? decoded['textUnderline'] as bool
              : false,
          titleMode: _titleMode(decoded['titleMode']),
          titleFontSizeOffset: _boundedDouble(
            decoded['titleFontSizeOffset'],
            fallback: 6,
            minimum: 0,
            maximum: 16,
          ),
          titleFontWeightValue: _titleFontWeightValue(decoded['titleFontWeightValue']),
          titleTopSpacing: _boundedDouble(
            decoded['titleTopSpacing'],
            fallback: 8,
            minimum: 0,
            maximum: 48,
          ),
          titleBottomSpacing: _boundedDouble(
            decoded['titleBottomSpacing'],
            fallback: 20,
            minimum: 0,
            maximum: 48,
          ),
          paragraphIndent: _paragraphIndent(decoded['paragraphIndent']),
          textFullJustify: decoded['textFullJustify'] is bool
              ? decoded['textFullJustify'] as bool
              : true,
          leftTapAction: _tapAction(
            decoded['leftTapAction'],
            ReaderTapAction.previousPage,
          ),
          centerTapAction: _tapAction(
            decoded['centerTapAction'],
            ReaderTapAction.toggleMenu,
          ),
          rightTapAction: _tapAction(
            decoded['rightTapAction'],
            ReaderTapAction.nextPage,
          ),
          longPressAction: _tapAction(
            decoded['longPressAction'],
            ReaderTapAction.addBookmark,
          ),
          leftTapWidthRatio: _boundedDouble(
            decoded['leftTapWidthRatio'],
            fallback: 0.3,
            minimum: 0.15,
            maximum: 0.45,
          ),
          rightTapWidthRatio: _boundedDouble(
            decoded['rightTapWidthRatio'],
            fallback: 0.3,
            minimum: 0.15,
            maximum: 0.45,
          ),
          volumeKeyTurnPage: decoded['volumeKeyTurnPage'] is bool
              ? decoded['volumeKeyTurnPage'] as bool
              : true,
          showClock: decoded['showClock'] is bool
              ? decoded['showClock'] as bool
              : true,
          showBattery: decoded['showBattery'] is bool
              ? decoded['showBattery'] as bool
              : true,
          useSystemBrightness: decoded['useSystemBrightness'] is bool
              ? decoded['useSystemBrightness'] as bool
              : true,
          readerBrightness: _boundedDouble(
            decoded['readerBrightness'],
            fallback: 0.5,
            minimum: 0.05,
            maximum: 1,
          ),
          orientationMode: _orientationMode(decoded['orientationMode']),
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
        'verticalPadding': config.verticalPadding,
        'letterSpacing': config.letterSpacing,
        'fontWeightValue': config.fontWeightValue,
        'textItalic': config.textItalic,
        'backgroundColorValue': config.backgroundColorValue,
        'textColorValue': config.textColorValue,
        'useReplaceRules': config.useReplaceRules,
        'keepScreenOn': config.keepScreenOn,
        'preDownloadCount': config.preDownloadCount,
        'readingMode': config.readingMode.name,
        'pageTurnStyle': config.pageTurnStyle.name,
        // 标记当前单书配置已经采用新版默认翻页迁移，避免覆盖用户后续手动选择。
        'horizontalCoverDefaultVersion': 1,
        'showHeaderFooter': config.showHeaderFooter,
        'showMenuToolLabels': config.showMenuToolLabels,
        'textShadow': config.textShadow,
        'textUnderline': config.textUnderline,
        'titleMode': config.titleMode.name,
        'titleFontSizeOffset': config.titleFontSizeOffset,
        'titleFontWeightValue': config.titleFontWeightValue,
        'titleTopSpacing': config.titleTopSpacing,
        'titleBottomSpacing': config.titleBottomSpacing,
        'paragraphIndent': config.paragraphIndent,
        'textFullJustify': config.textFullJustify,
        'leftTapAction': config.leftTapAction.name,
        'centerTapAction': config.centerTapAction.name,
        'rightTapAction': config.rightTapAction.name,
        'longPressAction': config.longPressAction.name,
        'leftTapWidthRatio': config.leftTapWidthRatio,
        'rightTapWidthRatio': config.rightTapWidthRatio,
        'volumeKeyTurnPage': config.volumeKeyTurnPage,
        'showClock': config.showClock,
        'showBattery': config.showBattery,
        'useSystemBrightness': config.useSystemBrightness,
        'readerBrightness': config.readerBrightness,
        'orientationMode': config.orientationMode.name,
      });
      return _cacheDao.upsert(Cache(key: _configKey(bookUrl), value: value));
    });
  }

  /// 将数字字段收窄为 double，非法类型使用默认值。
  double _double(Object? value, double fallback) {
    return value is num ? value.toDouble() : fallback;
  }

  /// 将数字字段限制到设置面板支持的闭区间，避免损坏缓存使 Slider 越界。
  double _boundedDouble(
    Object? value, {
    required double fallback,
    required double minimum,
    required double maximum,
  }) {
    /// 读取并应用默认值后的候选浮点数。
    final double candidate = _double(value, fallback);
    return candidate.clamp(minimum, maximum).toDouble();
  }

  /// 将数字字段收窄为 int，非法类型使用默认值。
  int _integer(Object? value, int fallback) {
    return value is num ? value.toInt() : fallback;
  }

  /// 把损坏或旧版本的字重值收窄为界面支持的稳定选项。
  int _fontWeightValue(Object? value) {
    /// JSON 中读取到的候选字重。
    final int candidate = _integer(value, 400);
    return <int>{300, 400, 500, 700}.contains(candidate) ? candidate : 400;
  }

  /// 把损坏或旧版本的标题字重值收窄为界面支持的稳定选项。
  int _titleFontWeightValue(Object? value) {
    /// JSON 中读取到的候选标题字重。
    final int candidate = _integer(value, 600);
    return <int>{300, 400, 500, 600, 700}.contains(candidate) ? candidate : 600;
  }

  /// 把损坏或旧版本的首行缩进收窄到设置面板支持的范围。
  int _paragraphIndent(Object? value) {
    /// JSON 中读取到的候选全角空格数量。
    final int candidate = _integer(value, 2);
    return candidate.clamp(0, 8).toInt();
  }

  /// 把损坏或旧版本的预下载数量收窄到界面支持的稳定选项。
  int _preDownloadCount(Object? value) {
    /// JSON 中读取到的候选数量。
    final int candidate = _integer(value, 10);
    return <int>{0, 2, 5, 10, 20}.contains(candidate) ? candidate : 10;
  }

  /// 把持久化名称收窄为受支持的阅读呈现方式。
  ReaderReadingMode _readingMode(Object? value) {
    if (value is String) {
      for (final ReaderReadingMode mode in ReaderReadingMode.values) {
        if (mode.name == value) {
          return mode;
        }
      }
    }
    return ReaderReadingMode.horizontalPaging;
  }

  /// 把持久化名称收窄为受支持的翻页动画策略。
  ReaderPageTurnStyle _pageTurnStyle(Object? value) {
    if (value is String) {
      for (final ReaderPageTurnStyle style in ReaderPageTurnStyle.values) {
        if (style.name == value) {
          return style;
        }
      }
    }
    return ReaderPageTurnStyle.cover;
  }

  /// 把持久化名称收窄为受支持的章节标题排版方式。
  ReaderTitleMode _titleMode(Object? value) {
    if (value is String) {
      for (final ReaderTitleMode mode in ReaderTitleMode.values) {
        if (mode.name == value) {
          return mode;
        }
      }
    }
    return ReaderTitleMode.left;
  }

  /// 把持久化名称收窄为受支持的正文触控动作。
  ReaderTapAction _tapAction(Object? value, ReaderTapAction fallback) {
    if (value is String) {
      for (final ReaderTapAction action in ReaderTapAction.values) {
        if (action.name == value) {
          return action;
        }
      }
    }
    return fallback;
  }

  /// 把持久化名称收窄为受支持的阅读方向策略；旧缓存缺少该字段时按 App 竖屏锁定默认值回退。
  ReaderOrientationMode _orientationMode(Object? value) {
    if (value is String) {
      for (final ReaderOrientationMode mode in ReaderOrientationMode.values) {
        if (mode.name == value) {
          return mode;
        }
      }
    }
    return ReaderOrientationMode.portrait;
  }

  /// 生成不泄漏原始 URL 的正文缓存键。
  String _contentKey(String bookUrl, String chapterUrl) {
    return 'reader:content:${_digest('$bookUrl\n$chapterUrl')}';
  }

  /// 生成不泄漏原始 URL 的锚点缓存键。
  String _anchorKey(String bookUrl) => 'reader:anchor:${_digest(bookUrl)}';

  /// 生成不泄漏原始 URL 的显示配置缓存键。
  String _configKey(String bookUrl) => 'reader:config:${_digest(bookUrl)}';

  /// 查找同一本书之前在任意页面成功显示过的封面地址；写入时用 deadline=0 永久保存，
  /// 应用重启后仍然可用。
  @override
  Future<String?> getCoverUrl(String name, String author) {
    return guardDataOperation<String?>(
      () => _cacheDao.getValidValue(_coverKey(name, author), DateTime.now().millisecondsSinceEpoch),
    );
  }

  /// 永久记录一次成功加载的封面地址，覆盖同一本书之前记住的旧地址。
  @override
  Future<void> saveCoverUrl(String name, String author, String url) {
    return guardDataOperation<void>(
      () => _cacheDao.upsert(Cache(key: _coverKey(name, author), value: url, deadline: 0)),
    );
  }

  /// 生成不泄漏书名/作者原文的封面地址缓存键。
  String _coverKey(String name, String author) => 'cover:${_digest('$name\n$author')}';

  /// 使用 SHA-256 将不受信任 URL 转换为固定长度缓存键片段。
  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
}
