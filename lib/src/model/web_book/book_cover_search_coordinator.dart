import 'dart:async';

import '../../domain/gateway/book_cover_candidate_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import 'book_search_coordinator.dart';

/// 封面候选的三级匹配层级，枚举顺序从高到低。
enum BookCoverMatchLevel {
  /// 书名和非空目标作者都精确匹配。
  exactTitleAndAuthor,

  /// 书名精确匹配，作者不相同或目标作者为空。
  exactTitle,

  /// 书名仅满足双向包含关系。
  fuzzyTitle,
}

/// 封面选择面板展示的单个网络候选。
final class BookCoverCandidate {
  /// 创建不可变封面候选。
  const BookCoverCandidate({
    required this.book,
    required this.coverUrl,
    required this.matchLevel,
  });

  /// 产生封面的搜索结果。
  final SearchBook book;

  /// 已清理且保证非空的封面地址。
  final String coverUrl;

  /// 当前候选命中的最高匹配层级。
  final BookCoverMatchLevel matchLevel;
}

/// 封面面板初始化后的书源快照和已有候选。
final class BookCoverSearchPreparation {
  /// 创建初始化结果。
  BookCoverSearchPreparation({
    required this.visibleSourceCount,
    required List<BookSource> enabledSources,
    required List<BookCoverCandidate> candidates,
    required this.matchLevel,
  }) : enabledSources = List<BookSource>.unmodifiable(enabledSources),
       candidates = List<BookCoverCandidate>.unmodifiable(candidates);

  /// 当前可见书源总数。
  final int visibleSourceCount;

  /// 当前可见且已启用的书源快照。
  final List<BookSource> enabledSources;

  /// 已有数据中当前最高层级的候选。
  final List<BookCoverCandidate> candidates;

  /// 当前候选对应的匹配层级；没有候选时为空。
  final BookCoverMatchLevel? matchLevel;
}

/// 封面搜索向面板发布的增量事件。
sealed class BookCoverSearchEvent {
  /// 限制事件类型只能由本文件声明。
  const BookCoverSearchEvent();
}

/// 最高候选层级或该层候选内容发生变化。
final class BookCoverCandidatesChangedEvent extends BookCoverSearchEvent {
  /// 创建不可变候选更新事件。
  BookCoverCandidatesChangedEvent({
    required List<BookCoverCandidate> candidates,
    required this.matchLevel,
  }) : candidates = List<BookCoverCandidate>.unmodifiable(candidates);

  /// 当前应展示的最高层级候选。
  final List<BookCoverCandidate> candidates;

  /// 当前展示层级。
  final BookCoverMatchLevel matchLevel;
}

/// 单书源封面搜索失败，但其他来源仍可继续。
final class BookCoverSearchFailureEvent extends BookCoverSearchEvent {
  /// 创建失败事件。
  const BookCoverSearchFailureEvent(this.failure);

  /// 可安全展示的单书源失败摘要。
  final BookSearchSourceFailure failure;
}

/// 封面搜索进度更新。
final class BookCoverSearchProgressEvent extends BookCoverSearchEvent {
  /// 创建进度事件。
  const BookCoverSearchProgressEvent(this.progress);

  /// 复用普通搜书的有限并发进度。
  final BookSearchProgress progress;
}

/// 组合已有候选、SQLite 缓存和有限并发实时搜索，并执行三级候选升级。
final class BookCoverSearchCoordinator {
  /// 创建面板生命周期独占的封面搜索协调器。
  BookCoverSearchCoordinator({
    required BookSearchCoordinator searchCoordinator,
    required BookCoverCandidateGateway candidateGateway,
  }) : _searchCoordinator = searchCoordinator,
       _candidateGateway = candidateGateway;

  /// 普通搜书有限并发调度器。
  final BookSearchCoordinator _searchCoordinator;

  /// `searchBooks` 派生缓存边界。
  final BookCoverCandidateGateway _candidateGateway;

  /// 当前目标书籍。
  Book? _targetBook;

  /// 当前成人内容规则下可参与候选展示的书源 URL。
  Set<String> _enabledSourceUrls = const <String>{};

  /// 按匹配层级保存去重后的候选，低层级只暂存不与高层级混合展示。
  final Map<BookCoverMatchLevel, Map<String, SearchBook>> _buckets =
      <BookCoverMatchLevel, Map<String, SearchBook>>{
        for (final BookCoverMatchLevel level in BookCoverMatchLevel.values)
          level: <String, SearchBook>{},
      };

  /// 读取书源可用性、合并详情已有候选和 SQLite 缓存。
  Future<BookCoverSearchPreparation> prepare({
    required Book book,
    required List<SearchBook> initialCandidates,
  }) async {
    _targetBook = book;
    for (final Map<String, SearchBook> bucket in _buckets.values) {
      bucket.clear();
    }
    /// 当前内容策略过滤后的书源可用性。
    final BookSearchSourceAvailability availability =
        await _searchCoordinator.loadSourceAvailability();
    _enabledSourceUrls = availability.enabledSources
        .map((BookSource source) => source.bookSourceUrl)
        .toSet();
    _addCandidates(initialCandidates);
    try {
      /// 目标书名附近且仍属于当前启用可见书源的缓存候选。
      final List<SearchBook> cached =
          await _candidateGateway.loadCandidates(
        bookName: book.name,
        enabledSourceUrls: _enabledSourceUrls,
      );
      _addCandidates(cached);
    } on Object {
      // 缓存只是搜索加速层，读取失败时仍允许实时搜索完成核心流程。
    }
    /// 当前最高非空候选层级。
    final BookCoverMatchLevel? level = _bestLevel();
    return BookCoverSearchPreparation(
      visibleSourceCount: availability.visibleSourceCount,
      enabledSources: availability.enabledSources,
      candidates: level == null
          ? const <BookCoverCandidate>[]
          : _candidatesForLevel(level),
      matchLevel: level,
    );
  }

  /// 搜索准备阶段固定的启用书源数量。
  int get enabledSourceCount => _enabledSourceUrls.length;

  /// 在全部当前启用书源中开始搜索，并把结果增量升级到最高匹配层级。
  Future<BookSearchRun> startSearch({
    required void Function(BookCoverSearchEvent event) onEvent,
  }) async {
    /// prepare 已固定的目标书籍。
    final Book? targetBook = _targetBook;
    if (targetBook == null) {
      throw StateError('封面搜索尚未完成初始化');
    }
    return _searchCoordinator.start(
      keyword: targetBook.name,
      selectedSourceUrls: _enabledSourceUrls,
      onEvent: (BookSearchEvent event) {
        switch (event) {
          case BookSearchResultsEvent(books: final List<SearchBook> books):
            /// 本批次中满足非空封面和至少模糊书名匹配的候选。
            final List<SearchBook> accepted = books.where(
              (SearchBook book) =>
                  (book.coverUrl?.trim().isNotEmpty ?? false) &&
                  _matchLevel(book) != null,
            ).toList(growable: false);
            if (accepted.isEmpty) {
              return;
            }
            _addCandidates(accepted);
            unawaited(
              _candidateGateway
                  .saveCandidates(accepted)
                  .catchError((Object _) {}),
            );
            /// 新结果进入后重新选择最高非空层级，实现模糊到精确的动态升级。
            final BookCoverMatchLevel? level = _bestLevel();
            if (level != null) {
              onEvent(
                BookCoverCandidatesChangedEvent(
                  candidates: _candidatesForLevel(level),
                  matchLevel: level,
                ),
              );
            }
          case BookSearchFailureEvent(failure: final failure):
            onEvent(BookCoverSearchFailureEvent(failure));
          case BookSearchProgressEvent(progress: final progress):
            onEvent(BookCoverSearchProgressEvent(progress));
        }
      },
    );
  }

  /// 将候选分配到各自层级，并按封面 URL 去重。
  void _addCandidates(Iterable<SearchBook> books) {
    /// 当前目标书籍在网格中已经由“当前/默认封面”专用项展示的地址。
    final Set<String> reservedCoverUrls = <String>{
      if (_targetBook?.coverUrl?.trim().isNotEmpty ?? false)
        _targetBook?.coverUrl?.trim() ?? '',
      if (_targetBook?.customCoverUrl?.trim().isNotEmpty ?? false)
        _targetBook?.customCoverUrl?.trim() ?? '',
    };
    for (final SearchBook book in books) {
      if (!_enabledSourceUrls.contains(book.origin)) {
        continue;
      }
      /// 非空且已经去除首尾空白的候选封面。
      final String coverUrl = book.coverUrl?.trim() ?? '';
      if (coverUrl.isEmpty || reservedCoverUrls.contains(coverUrl)) {
        continue;
      }
      /// 当前结果能够进入的匹配层级。
      final BookCoverMatchLevel? level = _matchLevel(book);
      if (level == null) {
        continue;
      }
      _buckets[level]?.putIfAbsent(coverUrl, () => book);
    }
  }

  /// 返回当前存在候选的最高匹配层级。
  BookCoverMatchLevel? _bestLevel() {
    for (final BookCoverMatchLevel level in BookCoverMatchLevel.values) {
      if (_buckets[level]?.isNotEmpty ?? false) {
        return level;
      }
    }
    return null;
  }

  /// 构建单一层级的稳定候选列表，不把低优先级结果混入。
  List<BookCoverCandidate> _candidatesForLevel(
    BookCoverMatchLevel level,
  ) {
    /// 当前层级按封面 URL 去重后的搜索结果。
    final List<SearchBook> books =
        _buckets[level]?.values.toList(growable: false) ??
        const <SearchBook>[];
    books.sort((SearchBook left, SearchBook right) {
      final int order = left.originOrder.compareTo(right.originOrder);
      if (order != 0) {
        return order;
      }
      final int origin = left.originName.compareTo(right.originName);
      return origin != 0 ? origin : left.bookUrl.compareTo(right.bookUrl);
    });
    return List<BookCoverCandidate>.unmodifiable(
      books.map(
        (SearchBook book) => BookCoverCandidate(
          book: book,
          coverUrl: book.coverUrl?.trim() ?? '',
          matchLevel: level,
        ),
      ),
    );
  }

  /// 按用户确认的三级顺序判断候选。
  BookCoverMatchLevel? _matchLevel(SearchBook candidate) {
    /// 当前目标书籍。
    final Book? target = _targetBook;
    if (target == null) {
      return null;
    }
    /// 用于精确比较的目标书名。
    final String targetTitle = _normalizeExactTitle(target.name);
    /// 用于精确比较的候选书名。
    final String candidateTitle = _normalizeExactTitle(candidate.name);
    if (targetTitle.isEmpty || candidateTitle.isEmpty) {
      return null;
    }
    if (targetTitle == candidateTitle) {
      /// 目标作者为空时不把两个空作者误判为最高置信候选。
      final String targetAuthor = _normalizeAuthor(target.author);
      if (targetAuthor.isNotEmpty &&
          targetAuthor == _normalizeAuthor(candidate.author)) {
        return BookCoverMatchLevel.exactTitleAndAuthor;
      }
      return BookCoverMatchLevel.exactTitle;
    }
    /// 精确层级没有命中后才执行更宽松的书名包含判断。
    final String targetFuzzy = _normalizeFuzzyTitle(target.name);
    final String candidateFuzzy = _normalizeFuzzyTitle(candidate.name);
    final int shorterLength = targetFuzzy.runes.length <
            candidateFuzzy.runes.length
        ? targetFuzzy.runes.length
        : candidateFuzzy.runes.length;
    if (shorterLength < 2) {
      return null;
    }
    if (targetFuzzy.contains(candidateFuzzy) ||
        candidateFuzzy.contains(targetFuzzy)) {
      return BookCoverMatchLevel.fuzzyTitle;
    }
    return null;
  }

  /// 精确书名只折叠空白并忽略英文字母大小写，不删除标点。
  String _normalizeExactTitle(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  /// 作者沿用换源流程的前后缀清理，再折叠空白并忽略大小写。
  String _normalizeAuthor(String value) {
    return value
        .replaceFirst(RegExp(r'^\s*作\s*者[:：\s]+'), '')
        .replaceFirst(RegExp(r'\s*著\s*$'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();
  }

  /// 模糊书名额外移除书名号、括号、空白和常见连接符。
  String _normalizeFuzzyTitle(String value) {
    return _normalizeExactTitle(value).replaceAll(
      RegExp(r'''[\s《》〈〉「」『』【】\[\]（）()·:：,，._—\-]+'''),
      '',
    );
  }
}
