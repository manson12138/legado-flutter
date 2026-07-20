import 'dart:convert';

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_group.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/cache.dart';
import '../../domain/model/cookie.dart';
import '../../domain/model/download_task.dart';
import '../../domain/model/read_config.dart';
import '../../domain/model/replace_rule.dart';
import '../../domain/model/search_book.dart';
import 'sqlite_row_reader.dart';

/// 将布尔值转换为 SQLite 使用的 0/1 整数。
int boolToSqlite(bool value) => value ? 1 : 0;

/// 将可空布尔值转换为 SQLite 使用的可空 0/1 整数。
int? nullableBoolToSqlite(bool? value) => value == null ? null : boolToSqlite(value);

/// 将单书阅读配置编码为数据库 JSON 文本。
String? readConfigToSqlite(ReadConfig? config) {
  if (config == null) {
    return null;
  }
  return jsonEncode(config.toJson());
}

/// 从数据库 JSON 文本恢复单书阅读配置；结构错误由 Repository 转换为领域错误。
ReadConfig? readConfigFromSqlite(String? source) {
  if (source == null) {
    return null;
  }
  /// 数据库中保存的已解码 JSON 根值。
  final Object? decoded = jsonDecode(source);
  if (decoded is! Map<Object?, Object?>) {
    throw const FormatException('readConfig 不是 JSON 对象');
  }
  /// 只接受字符串键的配置字段。
  final Map<String, Object?> json = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in decoded.entries) {
    /// 当前配置字段的字符串键。
    final Object? key = entry.key;
    if (key is String) {
      json[key] = entry.value;
    }
  }
  return ReadConfig.fromJson(json);
}

/// 将 [Book] 转换为 `books` 表写入参数。
Map<String, Object?> bookToMap(Book book) => <String, Object?>{
      'bookUrl': book.bookUrl,
      'tocUrl': book.tocUrl,
      'origin': book.origin,
      'originName': book.originName,
      'name': book.name,
      'author': book.author,
      'kind': book.kind,
      'customTag': book.customTag,
      'coverUrl': book.coverUrl,
      'customCoverUrl': book.customCoverUrl,
      'intro': book.intro,
      'customIntro': book.customIntro,
      'remark': book.remark,
      'charset': book.charset,
      'type': book.type,
      '`group`': book.group,
      'latestChapterTitle': book.latestChapterTitle,
      'latestChapterTime': book.latestChapterTime,
      'lastCheckTime': book.lastCheckTime,
      'lastCheckCount': book.lastCheckCount,
      'totalChapterNum': book.totalChapterNum,
      'durChapterTitle': book.durChapterTitle,
      'durChapterIndex': book.durChapterIndex,
      'durChapterPos': book.durChapterPos,
      'durChapterTime': book.durChapterTime,
      'wordCount': book.wordCount,
      'canUpdate': boolToSqlite(book.canUpdate),
      '`order`': book.order,
      'originOrder': book.originOrder,
      'variable': book.variable,
      'readConfig': readConfigToSqlite(book.readConfig),
      'syncTime': book.syncTime,
    };

/// 从 `books` 表行恢复 [Book]。
Book bookFromMap(Map<String, Object?> row) {
  /// 对当前书籍行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return Book(
    bookUrl: reader.requiredString('bookUrl'),
    tocUrl: reader.requiredString('tocUrl'),
    origin: reader.requiredString('origin'),
    originName: reader.requiredString('originName'),
    name: reader.requiredString('name'),
    author: reader.requiredString('author'),
    kind: reader.nullableString('kind'),
    customTag: reader.nullableString('customTag'),
    coverUrl: reader.nullableString('coverUrl'),
    customCoverUrl: reader.nullableString('customCoverUrl'),
    intro: reader.nullableString('intro'),
    customIntro: reader.nullableString('customIntro'),
    remark: reader.nullableString('remark'),
    charset: reader.nullableString('charset'),
    type: reader.requiredInt('type'),
    group: reader.requiredInt('group'),
    latestChapterTitle: reader.nullableString('latestChapterTitle'),
    latestChapterTime: reader.requiredInt('latestChapterTime'),
    lastCheckTime: reader.requiredInt('lastCheckTime'),
    lastCheckCount: reader.requiredInt('lastCheckCount'),
    totalChapterNum: reader.requiredInt('totalChapterNum'),
    durChapterTitle: reader.nullableString('durChapterTitle'),
    durChapterIndex: reader.requiredInt('durChapterIndex'),
    durChapterPos: reader.requiredInt('durChapterPos'),
    durChapterTime: reader.requiredInt('durChapterTime'),
    wordCount: reader.nullableString('wordCount'),
    canUpdate: reader.requiredBool('canUpdate'),
    order: reader.requiredInt('order'),
    originOrder: reader.requiredInt('originOrder'),
    variable: reader.nullableString('variable'),
    readConfig: readConfigFromSqlite(reader.nullableString('readConfig')),
    syncTime: reader.requiredInt('syncTime'),
  );
}

/// 将 [BookSource] 转换为 `book_sources` 表写入参数。
Map<String, Object?> bookSourceToMap(BookSource source) => <String, Object?>{
      'bookSourceUrl': source.bookSourceUrl,
      'bookSourceName': source.bookSourceName,
      'bookSourceGroup': source.bookSourceGroup,
      'bookSourceType': source.bookSourceType,
      'bookUrlPattern': source.bookUrlPattern,
      'customOrder': source.customOrder,
      'enabled': boolToSqlite(source.enabled),
      'enabledExplore': boolToSqlite(source.enabledExplore),
      'jsLib': source.jsLib,
      'enabledCookieJar': nullableBoolToSqlite(source.enabledCookieJar),
      'concurrentRate': source.concurrentRate,
      'header': source.header,
      'loginUrl': source.loginUrl,
      'loginUi': source.loginUi,
      'loginCheckJs': source.loginCheckJs,
      'coverDecodeJs': source.coverDecodeJs,
      'bookSourceComment': source.bookSourceComment,
      'variableComment': source.variableComment,
      'lastUpdateTime': source.lastUpdateTime,
      'respondTime': source.respondTime,
      'weight': source.weight,
      'exploreUrl': source.exploreUrl,
      'exploreScreen': source.exploreScreen,
      'ruleExplore': source.ruleExplore,
      'searchUrl': source.searchUrl,
      'ruleSearch': source.ruleSearch,
      'ruleBookInfo': source.ruleBookInfo,
      'ruleToc': source.ruleToc,
      'ruleContent': source.ruleContent,
      'ruleReview': source.ruleReview,
      'eventListener': boolToSqlite(source.eventListener),
      'customButton': boolToSqlite(source.customButton),
      'homepageModules': source.homepageModules,
      'extraFieldsJson': source.extraFieldsJson,
      'sourceScore': source.sourceScore,
      'pinned': boolToSqlite(source.pinned),
    };

/// 从 `book_sources` 表行恢复 [BookSource]。
BookSource bookSourceFromMap(Map<String, Object?> row) {
  /// 对当前书源行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return BookSource(
    bookSourceUrl: reader.requiredString('bookSourceUrl'),
    bookSourceName: reader.requiredString('bookSourceName'),
    bookSourceGroup: reader.nullableString('bookSourceGroup'),
    bookSourceType: reader.requiredInt('bookSourceType'),
    bookUrlPattern: reader.nullableString('bookUrlPattern'),
    customOrder: reader.requiredInt('customOrder'),
    enabled: reader.requiredBool('enabled'),
    enabledExplore: reader.requiredBool('enabledExplore'),
    jsLib: reader.nullableString('jsLib'),
    enabledCookieJar: reader.nullableBool('enabledCookieJar'),
    concurrentRate: reader.nullableString('concurrentRate'),
    header: reader.nullableString('header'),
    loginUrl: reader.nullableString('loginUrl'),
    loginUi: reader.nullableString('loginUi'),
    loginCheckJs: reader.nullableString('loginCheckJs'),
    coverDecodeJs: reader.nullableString('coverDecodeJs'),
    bookSourceComment: reader.nullableString('bookSourceComment'),
    variableComment: reader.nullableString('variableComment'),
    lastUpdateTime: reader.requiredInt('lastUpdateTime'),
    respondTime: reader.requiredInt('respondTime'),
    weight: reader.requiredInt('weight'),
    exploreUrl: reader.nullableString('exploreUrl'),
    exploreScreen: reader.nullableString('exploreScreen'),
    ruleExplore: reader.nullableString('ruleExplore'),
    searchUrl: reader.nullableString('searchUrl'),
    ruleSearch: reader.nullableString('ruleSearch'),
    ruleBookInfo: reader.nullableString('ruleBookInfo'),
    ruleToc: reader.nullableString('ruleToc'),
    ruleContent: reader.nullableString('ruleContent'),
    ruleReview: reader.nullableString('ruleReview'),
    eventListener: reader.requiredBool('eventListener'),
    customButton: reader.requiredBool('customButton'),
    homepageModules: reader.nullableString('homepageModules'),
    extraFieldsJson: reader.nullableString('extraFieldsJson'),
    sourceScore: reader.requiredInt('sourceScore'),
    pinned: reader.requiredBool('pinned'),
  );
}

/// 将 [BookChapter] 转换为 `chapters` 表写入参数。
Map<String, Object?> bookChapterToMap(BookChapter chapter) => <String, Object?>{
      'url': chapter.url,
      'title': chapter.title,
      'isVolume': boolToSqlite(chapter.isVolume),
      'baseUrl': chapter.baseUrl,
      'bookUrl': chapter.bookUrl,
      '`index`': chapter.index,
      'isVip': boolToSqlite(chapter.isVip),
      'isPay': boolToSqlite(chapter.isPay),
      'resourceUrl': chapter.resourceUrl,
      'tag': chapter.tag,
      'wordCount': chapter.wordCount,
      'start': chapter.start,
      'end': chapter.end,
      'startFragmentId': chapter.startFragmentId,
      'endFragmentId': chapter.endFragmentId,
      'variable': chapter.variable,
      'reviewImg': chapter.reviewImg,
    };

/// 从 `chapters` 表行恢复 [BookChapter]。
BookChapter bookChapterFromMap(Map<String, Object?> row) {
  /// 对当前章节行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return BookChapter(
    url: reader.requiredString('url'),
    title: reader.requiredString('title'),
    isVolume: reader.requiredBool('isVolume'),
    baseUrl: reader.requiredString('baseUrl'),
    bookUrl: reader.requiredString('bookUrl'),
    index: reader.requiredInt('index'),
    isVip: reader.requiredBool('isVip'),
    isPay: reader.requiredBool('isPay'),
    resourceUrl: reader.nullableString('resourceUrl'),
    tag: reader.nullableString('tag'),
    wordCount: reader.nullableString('wordCount'),
    start: reader.nullableInt('start'),
    end: reader.nullableInt('end'),
    startFragmentId: reader.nullableString('startFragmentId'),
    endFragmentId: reader.nullableString('endFragmentId'),
    variable: reader.nullableString('variable'),
    reviewImg: reader.nullableString('reviewImg'),
  );
}

/// 将 [BookGroup] 转换为 `book_groups` 表写入参数。
Map<String, Object?> bookGroupToMap(BookGroup group) => <String, Object?>{
      'groupId': group.groupId,
      'groupName': group.groupName,
      'cover': group.cover,
      '`order`': group.order,
      'enableRefresh': boolToSqlite(group.enableRefresh),
      'show': boolToSqlite(group.show),
      'bookSort': group.bookSort,
      'isPrivate': boolToSqlite(group.isPrivate),
    };

/// 从 `book_groups` 表行恢复 [BookGroup]。
BookGroup bookGroupFromMap(Map<String, Object?> row) {
  /// 对当前分组行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return BookGroup(
    groupId: reader.requiredInt('groupId'),
    groupName: reader.requiredString('groupName'),
    cover: reader.nullableString('cover'),
    order: reader.requiredInt('order'),
    enableRefresh: reader.requiredBool('enableRefresh'),
    show: reader.requiredBool('show'),
    bookSort: reader.requiredInt('bookSort'),
    isPrivate: reader.requiredBool('isPrivate'),
  );
}

/// 将 [SearchBook] 转换为 `searchBooks` 表写入参数。
Map<String, Object?> searchBookToMap(SearchBook book) => <String, Object?>{
      'bookUrl': book.bookUrl,
      'origin': book.origin,
      'originName': book.originName,
      'type': book.type,
      'name': book.name,
      'author': book.author,
      'kind': book.kind,
      'coverUrl': book.coverUrl,
      'intro': book.intro,
      'wordCount': book.wordCount,
      'latestChapterTitle': book.latestChapterTitle,
      'tocUrl': book.tocUrl,
      'time': book.time,
      'variable': book.variable,
      'originOrder': book.originOrder,
      'chapterWordCountText': book.chapterWordCountText,
      'chapterWordCount': book.chapterWordCount,
      'respondTime': book.respondTime,
    };

/// 从 `searchBooks` 表行恢复 [SearchBook]。
SearchBook searchBookFromMap(Map<String, Object?> row) {
  /// 对当前搜索结果行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return SearchBook(
    bookUrl: reader.requiredString('bookUrl'),
    origin: reader.requiredString('origin'),
    originName: reader.requiredString('originName'),
    type: reader.requiredInt('type'),
    name: reader.requiredString('name'),
    author: reader.requiredString('author'),
    kind: reader.nullableString('kind'),
    coverUrl: reader.nullableString('coverUrl'),
    intro: reader.nullableString('intro'),
    wordCount: reader.nullableString('wordCount'),
    latestChapterTitle: reader.nullableString('latestChapterTitle'),
    tocUrl: reader.requiredString('tocUrl'),
    time: reader.requiredInt('time'),
    variable: reader.nullableString('variable'),
    originOrder: reader.requiredInt('originOrder'),
    chapterWordCountText: reader.nullableString('chapterWordCountText'),
    chapterWordCount: reader.requiredInt('chapterWordCount'),
    respondTime: reader.requiredInt('respondTime'),
  );
}

/// 将 [Bookmark] 转换为 `bookmarks` 表写入参数。
Map<String, Object?> bookmarkToMap(Bookmark bookmark) => <String, Object?>{
      'time': bookmark.time,
      'bookName': bookmark.bookName,
      'bookAuthor': bookmark.bookAuthor,
      'chapterIndex': bookmark.chapterIndex,
      'chapterPos': bookmark.chapterPos,
      'chapterName': bookmark.chapterName,
      'bookText': bookmark.bookText,
      'content': bookmark.content,
    };

/// 从 `bookmarks` 表行恢复 [Bookmark]。
Bookmark bookmarkFromMap(Map<String, Object?> row) {
  /// 对当前书签行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return Bookmark(
    time: reader.requiredInt('time'),
    bookName: reader.requiredString('bookName'),
    bookAuthor: reader.requiredString('bookAuthor'),
    chapterIndex: reader.requiredInt('chapterIndex'),
    chapterPos: reader.requiredInt('chapterPos'),
    chapterName: reader.requiredString('chapterName'),
    bookText: reader.requiredString('bookText'),
    content: reader.requiredString('content'),
  );
}

/// 将 [Cookie] 转换为 `cookies` 表写入参数。
Map<String, Object?> cookieToMap(Cookie cookie) => <String, Object?>{
      'url': cookie.url,
      'cookie': cookie.cookie,
    };

/// 从 `cookies` 表行恢复 [Cookie]。
Cookie cookieFromMap(Map<String, Object?> row) {
  /// 对当前 Cookie 行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return Cookie(
    url: reader.requiredString('url'),
    cookie: reader.requiredString('cookie'),
  );
}

/// 将 [Cache] 转换为 `caches` 表写入参数。
Map<String, Object?> cacheToMap(Cache cache) => <String, Object?>{
      '`key`': cache.key,
      'value': cache.value,
      'deadline': cache.deadline,
    };

/// 从 `caches` 表行恢复 [Cache]。
Cache cacheFromMap(Map<String, Object?> row) {
  /// 对当前缓存行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return Cache(
    key: reader.requiredString('key'),
    value: reader.nullableString('value'),
    deadline: reader.requiredInt('deadline'),
  );
}

/// 将 [DownloadTask] 转换为 `download_tasks` 表写入参数。
Map<String, Object?> downloadTaskToMap(DownloadTask task) => <String, Object?>{
      'bookUrl': task.bookUrl,
      'chapterIndex': task.chapterIndex,
      'status': task.status.name,
      'retryCount': task.retryCount,
      'updatedAt': task.updatedAt,
    };

/// 从 `download_tasks` 表行恢复 [DownloadTask]。
DownloadTask downloadTaskFromMap(Map<String, Object?> row) {
  /// 对当前下载任务行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return DownloadTask(
    bookUrl: reader.requiredString('bookUrl'),
    chapterIndex: reader.requiredInt('chapterIndex'),
    status: DownloadTaskStatus.values.byName(reader.requiredString('status')),
    retryCount: reader.requiredInt('retryCount'),
    updatedAt: reader.requiredInt('updatedAt'),
  );
}

/// 将 [ReplaceRule] 转换为 `replace_rules` 表写入参数。
Map<String, Object?> replaceRuleToMap(ReplaceRule rule) => <String, Object?>{
      if (rule.id != null) 'id': rule.id,
      'name': rule.name,
      '`group`': rule.group,
      'pattern': rule.pattern,
      'replacement': rule.replacement,
      'scope': rule.scope,
      'scopeTitle': boolToSqlite(rule.scopeTitle),
      'scopeContent': boolToSqlite(rule.scopeContent),
      'excludeScope': rule.excludeScope,
      'isEnabled': boolToSqlite(rule.isEnabled),
      'isRegex': boolToSqlite(rule.isRegex),
      'timeoutMillisecond': rule.timeoutMillisecond,
      'sortOrder': rule.order,
    };

/// 从 `replace_rules` 表行恢复 [ReplaceRule]。
ReplaceRule replaceRuleFromMap(Map<String, Object?> row) {
  /// 对当前净化规则行执行安全类型读取的解析器。
  final SqliteRowReader reader = SqliteRowReader(row);
  return ReplaceRule(
    id: reader.requiredInt('id'),
    name: reader.requiredString('name'),
    group: reader.nullableString('group'),
    pattern: reader.requiredString('pattern'),
    replacement: reader.requiredString('replacement'),
    scope: reader.nullableString('scope'),
    scopeTitle: reader.requiredBool('scopeTitle'),
    scopeContent: reader.requiredBool('scopeContent'),
    excludeScope: reader.nullableString('excludeScope'),
    isEnabled: reader.requiredBool('isEnabled'),
    isRegex: reader.requiredBool('isRegex'),
    timeoutMillisecond: reader.requiredInt('timeoutMillisecond'),
    order: reader.requiredInt('sortOrder'),
  );
}
