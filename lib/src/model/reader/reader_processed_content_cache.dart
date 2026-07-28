import 'dart:collection';

import '../../domain/model/reader_content.dart';

/// 标识一份可以跨阅读路由复用的处理后正文。
///
/// 缓存身份包含用户、书籍、章节、正文处理配置和替换规则表修订号，不包含字号、行距、
/// 边距等只影响分页的显示参数。
final class ReaderProcessedContentCacheKey {
  /// 创建不可变处理后正文缓存键。
  const ReaderProcessedContentCacheKey({
    required this.userId,
    required this.userGeneration,
    required this.bookUrl,
    required this.chapterUrl,
    required this.useReplaceRules,
    required this.chineseConversionMode,
    required this.reSegmentContent,
    required this.replaceRuleRevision,
  });

  /// 当前游客或登录账号的本地作用域 ID。
  final int userId;

  /// 当前用户作用域切换代次，阻止退出后晚到结果在同 ID 再登录时复用。
  final int userGeneration;

  /// 当前书籍稳定 URL。
  final String bookUrl;

  /// 当前章节稳定 URL。
  final String chapterUrl;

  /// 本次处理是否应用正文替换规则。
  final bool useReplaceRules;

  /// 本次处理使用的简繁转换模式。
  final ReaderChineseConversionMode chineseConversionMode;

  /// 本次处理是否重新连接异常断行并切分长段。
  final bool reSegmentContent;

  /// 替换规则表最近一次提交修订；关闭替换规则时固定为零。
  final int replaceRuleRevision;

  /// 使用所有正文处理身份字段比较两个缓存键。
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReaderProcessedContentCacheKey &&
            other.userId == userId &&
            other.userGeneration == userGeneration &&
            other.bookUrl == bookUrl &&
            other.chapterUrl == chapterUrl &&
            other.useReplaceRules == useReplaceRules &&
            other.chineseConversionMode == chineseConversionMode &&
            other.reSegmentContent == reSegmentContent &&
            other.replaceRuleRevision == replaceRuleRevision;
  }

  /// 生成与相等性字段一致的哈希值。
  @override
  int get hashCode => Object.hash(
    userId,
    userGeneration,
    bookUrl,
    chapterUrl,
    useReplaceRules,
    chineseConversionMode,
    reSegmentContent,
    replaceRuleRevision,
  );
}

/// 一次正文缓存查询或处理任务使用的短生命周期令牌。
///
/// 原始正文被刷新、换源或删除时，缓存会把仍在处理的同章令牌标记为无效，阻止晚到旧结果
/// 重新写回应用级 LRU。
final class ReaderProcessedContentCacheToken {
  /// 只允许 [ReaderProcessedContentCache] 创建任务令牌。
  ReaderProcessedContentCacheToken._(this.key);

  /// 本次任务捕获的稳定缓存身份。
  final ReaderProcessedContentCacheKey key;

  /// 令牌是否仍允许读取或写入缓存。
  bool _isValid = true;
}

/// 应用级处理后正文 LRU，只保存纯 [ReaderChapterContent] 数据。
///
/// 默认同时限制为最多三章和约 4 MiB。单章估算超过上限时允许调用页面继续显示，但不会
/// 留在应用级缓存。该对象不持有 Widget、Context、Controller、Stream、Timer 或取消令牌。
final class ReaderProcessedContentCache {
  /// 创建有界处理后正文缓存。
  ReaderProcessedContentCache({
    this.maximumEntryCount = 3,
    this.maximumEstimatedBytes = 4 * 1024 * 1024,
  }) {
    if (maximumEntryCount <= 0) {
      throw ArgumentError.value(
        maximumEntryCount,
        'maximumEntryCount',
        '处理后正文缓存条目上限必须大于零',
      );
    }
    if (maximumEstimatedBytes <= 0) {
      throw ArgumentError.value(
        maximumEstimatedBytes,
        'maximumEstimatedBytes',
        '处理后正文缓存估算字节上限必须大于零',
      );
    }
  }

  /// 最多保留的处理后章节数量。
  final int maximumEntryCount;

  /// 允许保留的处理后正文估算总字节数。
  final int maximumEstimatedBytes;

  /// 按最近访问顺序保存的正文条目。
  final LinkedHashMap<
      ReaderProcessedContentCacheKey,
      _ReaderProcessedContentCacheEntry> _entries =
      LinkedHashMap<
        ReaderProcessedContentCacheKey,
        _ReaderProcessedContentCacheEntry
      >();

  /// 当前仍可能向缓存提交结果的短生命周期任务令牌。
  final Set<ReaderProcessedContentCacheToken> _activeTokens =
      <ReaderProcessedContentCacheToken>{};

  /// 当前全部条目的估算内存总量。
  int _estimatedBytes = 0;

  /// 最近一次参与键生成的替换规则表修订号。
  int? _replaceRuleRevision;

  /// 为一次查询或处理任务创建受失效控制的缓存令牌。
  ReaderProcessedContentCacheToken begin({
    required int userId,
    required int userGeneration,
    required String bookUrl,
    required String chapterUrl,
    required bool useReplaceRules,
    required ReaderChineseConversionMode chineseConversionMode,
    required bool reSegmentContent,
    required int replaceRuleRevision,
  }) {
    _synchronizeReplaceRuleRevision(replaceRuleRevision);
    /// 关闭替换规则时不让无关规则编辑改变缓存身份。
    final int effectiveReplaceRuleRevision = useReplaceRules
        ? replaceRuleRevision
        : 0;
    /// 本次任务不可变的完整缓存键。
    final ReaderProcessedContentCacheKey key =
        ReaderProcessedContentCacheKey(
          userId: userId,
          userGeneration: userGeneration,
          bookUrl: bookUrl,
          chapterUrl: chapterUrl,
          useReplaceRules: useReplaceRules,
          chineseConversionMode: chineseConversionMode,
          reSegmentContent: reSegmentContent,
          replaceRuleRevision: effectiveReplaceRuleRevision,
        );
    /// 由调用方在 finally 中结束的短生命周期令牌。
    final ReaderProcessedContentCacheToken token =
        ReaderProcessedContentCacheToken._(key);
    _activeTokens.add(token);
    return token;
  }

  /// 读取并提升一个仍有效令牌对应的最近使用正文。
  ReaderChapterContent? take(ReaderProcessedContentCacheToken token) {
    if (!token._isValid || !_activeTokens.contains(token)) {
      return null;
    }
    /// 从原位置移除以便重新插入到 LRU 尾部的命中条目。
    final _ReaderProcessedContentCacheEntry? entry = _entries.remove(
      token.key,
    );
    if (entry == null) {
      return null;
    }
    _entries[token.key] = entry;
    return entry.content;
  }

  /// 在令牌仍有效时保存处理后正文，并执行条目数和估算字节双重淘汰。
  void store(
    ReaderProcessedContentCacheToken token,
    ReaderChapterContent content,
  ) {
    if (!token._isValid ||
        !_activeTokens.contains(token) ||
        content.chapterUrl != token.key.chapterUrl) {
      return;
    }
    /// 缓存命中时应明确标记为来自缓存，同时复用原有不可变字符串和块对象。
    final ReaderChapterContent cachedContent = content.fromCache
        ? content
        : ReaderChapterContent(
            chapterUrl: content.chapterUrl,
            title: content.title,
            text: content.text,
            blocks: content.blocks,
            images: content.images,
            effectiveReplaceRuleCount: content.effectiveReplaceRuleCount,
            fromCache: true,
          );
    /// 当前纯正文对象的保守内存估算。
    final int estimatedBytes = _estimateContentBytes(cachedContent);
    /// 同一个键可能已有的旧条目。
    final _ReaderProcessedContentCacheEntry? previous = _entries.remove(
      token.key,
    );
    if (previous != null) {
      _estimatedBytes -= previous.estimatedBytes;
    }
    if (estimatedBytes > maximumEstimatedBytes) {
      return;
    }
    _entries[token.key] = _ReaderProcessedContentCacheEntry(
      content: cachedContent,
      estimatedBytes: estimatedBytes,
    );
    _estimatedBytes += estimatedBytes;
    _trimToLimits();
  }

  /// 结束一次查询或处理任务，释放缓存对短生命周期令牌的引用。
  void end(ReaderProcessedContentCacheToken token) {
    _activeTokens.remove(token);
    token._isValid = false;
  }

  /// 使指定书籍章节的已缓存结果和正在处理的旧任务同时失效。
  void invalidateChapter(String bookUrl, String chapterUrl) {
    _removeWhere(
      (ReaderProcessedContentCacheKey key) =>
          key.bookUrl == bookUrl && key.chapterUrl == chapterUrl,
    );
    _invalidateTokens(
      (ReaderProcessedContentCacheKey key) =>
          key.bookUrl == bookUrl && key.chapterUrl == chapterUrl,
    );
  }

  /// 使一本书的全部处理后正文和正在处理的旧任务同时失效。
  void invalidateBook(String bookUrl) {
    _removeWhere(
      (ReaderProcessedContentCacheKey key) => key.bookUrl == bookUrl,
    );
    _invalidateTokens(
      (ReaderProcessedContentCacheKey key) => key.bookUrl == bookUrl,
    );
  }

  /// 清空全部可重建正文，并阻止清理前已经开始的任务晚到回写。
  void clear() {
    _entries.clear();
    _estimatedBytes = 0;
    for (final ReaderProcessedContentCacheToken token in _activeTokens) {
      token._isValid = false;
    }
    _activeTokens.clear();
    _replaceRuleRevision = null;
  }

  /// 替换规则表修订变化时只清除实际启用了替换规则的缓存和处理任务。
  void _synchronizeReplaceRuleRevision(int revision) {
    final int? previousRevision = _replaceRuleRevision;
    if (previousRevision == null) {
      _replaceRuleRevision = revision;
      return;
    }
    if (previousRevision == revision) {
      return;
    }
    _replaceRuleRevision = revision;
    _removeWhere(
      (ReaderProcessedContentCacheKey key) => key.useReplaceRules,
    );
    _invalidateTokens(
      (ReaderProcessedContentCacheKey key) => key.useReplaceRules,
    );
  }

  /// 按条件删除正文条目并同步估算总量。
  void _removeWhere(
    bool Function(ReaderProcessedContentCacheKey key) predicate,
  ) {
    /// 本轮需要删除的稳定键快照。
    final List<ReaderProcessedContentCacheKey> keys = _entries.keys
        .where(predicate)
        .toList(growable: false);
    for (final ReaderProcessedContentCacheKey key in keys) {
      /// 从 LRU 中移除的正文条目。
      final _ReaderProcessedContentCacheEntry? removed = _entries.remove(key);
      if (removed != null) {
        _estimatedBytes -= removed.estimatedBytes;
      }
    }
  }

  /// 按条件标记正在处理的任务无效，不主动持有或取消业务网络令牌。
  void _invalidateTokens(
    bool Function(ReaderProcessedContentCacheKey key) predicate,
  ) {
    for (final ReaderProcessedContentCacheToken token in _activeTokens) {
      if (predicate(token.key)) {
        token._isValid = false;
      }
    }
  }

  /// 从最久未使用条目开始淘汰，直到同时满足数量和字节上限。
  void _trimToLimits() {
    while (_entries.length > maximumEntryCount ||
        _estimatedBytes > maximumEstimatedBytes) {
      /// 当前最久未使用的缓存键。
      final ReaderProcessedContentCacheKey oldestKey = _entries.keys.first;
      /// 被容量策略淘汰的正文条目。
      final _ReaderProcessedContentCacheEntry? removed = _entries.remove(
        oldestKey,
      );
      if (removed != null) {
        _estimatedBytes -= removed.estimatedBytes;
      }
    }
  }

  /// 保守估算正文、分块和图片元数据的 Dart 堆占用，不统计 Widget 或分页对象。
  int _estimateContentBytes(ReaderChapterContent content) {
    /// 章节对象和不可变列表包装的固定近似开销。
    int total = 192;
    total += _estimateStringBytes(content.chapterUrl);
    total += _estimateStringBytes(content.title);
    total += _estimateStringBytes(content.text);
    for (final ReaderContentBlock block in content.blocks) {
      total += 96;
      total += _estimateStringBytes(block.id);
      total += _estimateStringBytes(block.text);
      total += _estimateStringBytes(block.resourceUrl);
      total += _estimateStringBytes(block.altText);
      total += _estimateStringBytes(block.resourceReferer);
    }
    for (final ReaderContentImage image in content.images) {
      total += 80;
      total += _estimateStringBytes(image.id);
      total += _estimateStringBytes(image.url);
      total += _estimateStringBytes(image.altText);
      total += _estimateStringBytes(image.referer);
    }
    return total;
  }

  /// 以 UTF-16 字符和对象头近似估算一个 Dart 字符串的堆占用。
  int _estimateStringBytes(String value) {
    return 24 + value.length * 2;
  }
}

/// 保存一个 LRU 正文值及其估算内存。
final class _ReaderProcessedContentCacheEntry {
  /// 创建内部正文缓存条目。
  const _ReaderProcessedContentCacheEntry({
    required this.content,
    required this.estimatedBytes,
  });

  /// 纯处理后章节正文。
  final ReaderChapterContent content;

  /// 当前正文的保守估算字节数。
  final int estimatedBytes;
}
