import 'dart:convert';

import '../../domain/model/book_source.dart';

/// 规则对象 JSON 无效或字段类型不兼容时抛出的异常。
final class SourceRuleFormatException implements Exception {
  /// 创建规则格式异常。
  const SourceRuleFormatException(this.message);

  /// 不包含用户正文的错误说明。
  final String message;

  @override
  String toString() => 'SourceRuleFormatException($message)';
}

/// 搜索列表普通规则。
final class SearchSourceRule {
  /// 创建搜索规则。
  const SearchSourceRule({
    this.bookList,
    this.name,
    this.author,
    this.intro,
    this.kind,
    this.lastChapter,
    this.updateTime,
    this.bookUrl,
    this.coverUrl,
    this.wordCount,
  });

  /// 书籍列表选择规则。
  final String? bookList;

  /// 书名规则。
  final String? name;

  /// 作者规则。
  final String? author;

  /// 简介规则。
  final String? intro;

  /// 分类规则。
  final String? kind;

  /// 最新章节规则。
  final String? lastChapter;

  /// 更新时间规则。
  final String? updateTime;

  /// 详情 URL 规则。
  final String? bookUrl;

  /// 封面 URL 规则。
  final String? coverUrl;

  /// 字数规则。
  final String? wordCount;
}

/// 书籍详情普通规则。
final class BookInfoSourceRule {
  /// 创建详情规则。
  const BookInfoSourceRule({
    this.init,
    this.name,
    this.author,
    this.intro,
    this.kind,
    this.lastChapter,
    this.updateTime,
    this.coverUrl,
    this.tocUrl,
    this.wordCount,
    this.canReName,
  });

  /// 详情解析前置普通规则。
  final String? init;

  /// 书名规则。
  final String? name;

  /// 作者规则。
  final String? author;

  /// 简介规则。
  final String? intro;

  /// 分类规则。
  final String? kind;

  /// 最新章节规则。
  final String? lastChapter;

  /// 更新时间规则。
  final String? updateTime;

  /// 封面 URL 规则。
  final String? coverUrl;

  /// 目录 URL 规则。
  final String? tocUrl;

  /// 字数规则。
  final String? wordCount;

  /// Android 用“规则是否非空”作为允许覆盖书名作者的标记，保留原始文本。
  final String? canReName;
}

/// 目录普通规则。
final class TocSourceRule {
  /// 创建目录规则。
  const TocSourceRule({
    this.chapterList,
    this.chapterName,
    this.chapterUrl,
    this.isVolume,
    this.isVip,
    this.isPay,
    this.updateTime,
    this.nextTocUrl,
    this.preUpdateJs,
    this.formatJs,
  });

  /// 章节列表选择规则。
  final String? chapterList;

  /// 章节标题规则。
  final String? chapterName;

  /// 章节 URL 规则。
  final String? chapterUrl;

  /// 卷标题规则。
  final String? isVolume;

  /// VIP 标识规则。
  final String? isVip;

  /// 购买标识规则。
  final String? isPay;

  /// 更新时间规则。
  final String? updateTime;

  /// 下一页目录 URL 规则。
  final String? nextTocUrl;

  /// M4 才支持的目录更新前 JavaScript。
  final String? preUpdateJs;

  /// M4 才支持的章节标题格式化 JavaScript。
  final String? formatJs;
}

/// 正文普通规则。
final class ContentSourceRule {
  /// 创建正文规则。
  const ContentSourceRule({
    this.content,
    this.subContent,
    this.title,
    this.nextContentUrl,
    this.replaceRegex,
    this.webJs,
    this.sourceRegex,
    this.imageDecode,
    this.payAction,
  });

  /// 正文内容规则。
  final String? content;

  /// 副正文规则，例如歌词。
  final String? subContent;

  /// 章节标题规则。
  final String? title;

  /// 下一页正文 URL 规则。
  final String? nextContentUrl;

  /// 正文完成后的替换规则。
  final String? replaceRegex;

  /// M4 才支持的 WebView JavaScript。
  final String? webJs;

  /// M4 才支持的源响应正则脚本组合字段。
  final String? sourceRegex;

  /// M4 才支持的图片解密 JavaScript。
  final String? imageDecode;

  /// M4 才支持的付费动作 JavaScript。
  final String? payAction;
}

/// 将 M2 保存的原始规则 JSON 收敛为 M3 强类型规则。
final class BookSourceRuleDecoder {
  /// 创建无状态规则解码器。
  const BookSourceRuleDecoder();

  /// 解码搜索规则。
  SearchSourceRule decodeSearch(BookSource source) {
    /// 原始规则对象。
    final Map<String, Object?> map = _decodeMap(source.ruleSearch, '搜索规则');
    return SearchSourceRule(
      bookList: _string(map, 'bookList'),
      name: _string(map, 'name'),
      author: _string(map, 'author'),
      intro: _string(map, 'intro'),
      kind: _string(map, 'kind'),
      lastChapter: _string(map, 'lastChapter'),
      updateTime: _string(map, 'updateTime'),
      bookUrl: _string(map, 'bookUrl'),
      coverUrl: _string(map, 'coverUrl'),
      wordCount: _string(map, 'wordCount'),
    );
  }

  /// 解码详情规则。
  BookInfoSourceRule decodeBookInfo(BookSource source) {
    /// 原始规则对象。
    final Map<String, Object?> map = _decodeMap(source.ruleBookInfo, '详情规则');
    return BookInfoSourceRule(
      init: _string(map, 'init'),
      name: _string(map, 'name'),
      author: _string(map, 'author'),
      intro: _string(map, 'intro'),
      kind: _string(map, 'kind'),
      lastChapter: _string(map, 'lastChapter'),
      updateTime: _string(map, 'updateTime'),
      coverUrl: _string(map, 'coverUrl'),
      tocUrl: _string(map, 'tocUrl'),
      wordCount: _string(map, 'wordCount'),
      canReName: _string(map, 'canReName'),
    );
  }

  /// 解码目录规则。
  TocSourceRule decodeToc(BookSource source) {
    /// 原始规则对象。
    final Map<String, Object?> map = _decodeMap(source.ruleToc, '目录规则');
    return TocSourceRule(
      chapterList: _string(map, 'chapterList'),
      chapterName: _string(map, 'chapterName'),
      chapterUrl: _string(map, 'chapterUrl'),
      isVolume: _string(map, 'isVolume'),
      isVip: _string(map, 'isVip'),
      isPay: _string(map, 'isPay'),
      updateTime: _string(map, 'updateTime'),
      nextTocUrl: _string(map, 'nextTocUrl'),
      preUpdateJs: _string(map, 'preUpdateJs'),
      formatJs: _string(map, 'formatJs'),
    );
  }

  /// 解码正文规则。
  ContentSourceRule decodeContent(BookSource source) {
    /// 原始规则对象。
    final Map<String, Object?> map = _decodeMap(source.ruleContent, '正文规则');
    return ContentSourceRule(
      content: _string(map, 'content'),
      subContent: _string(map, 'subContent'),
      title: _string(map, 'title'),
      nextContentUrl: _string(map, 'nextContentUrl'),
      replaceRegex: _string(map, 'replaceRegex'),
      webJs: _string(map, 'webJs'),
      sourceRegex: _string(map, 'sourceRegex'),
      imageDecode: _string(map, 'imageDecode'),
      payAction: _string(map, 'payAction'),
    );
  }

  /// 解码规则 JSON；兼容规则被再次编码成 JSON 字符串的导入数据。
  Map<String, Object?> _decodeMap(String? raw, String label) {
    if (raw == null || raw.trim().isEmpty) {
      return <String, Object?>{};
    }
    try {
      /// 第一次 JSON 解码结果。
      Object? decoded = jsonDecode(raw);
      if (decoded is String) {
        decoded = jsonDecode(decoded);
      }
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
      throw SourceRuleFormatException('$label必须是 JSON 对象');
    } on SourceRuleFormatException {
      rethrow;
    } on FormatException catch (error) {
      throw SourceRuleFormatException('$label JSON 无效：${error.message}');
    }
  }

  /// 读取可转成字符串的规则字段。
  String? _string(Map<String, Object?> map, String key) {
    /// 原始字段值。
    final Object? value = map[key];
    if (value == null) {
      return null;
    }
    return value is String ? value : value.toString();
  }

}
