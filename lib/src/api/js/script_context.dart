import 'dart:convert';

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../http/http_contract.dart';
import 'js_engine.dart';

/// 当前脚本所属的业务操作，用于宿主统一裁决登录和验证交互。
enum LegadoScriptOperation {
  unknown,
  search,
  explore,
  bookInfo,
  toc,
  content,
  download,
  changeSource,
}

/// 脚本请求浏览器、验证码或登录导航时的交互策略。
enum LegadoScriptInteractionPolicy {
  /// 不打开任何页面，以稳定错误结束当前书源任务。
  deny,

  /// 允许宿主申请用户交互；具体页面能力仍须由调用入口提供。
  allow,
}

/// `preUpdateJs` 可请求的 Android 目录刷新动作。
enum LegadoPreUpdateAction {
  /// 对应 Android `AnalyzeRule.reGetBook()`：精确搜索后重新加载详情。
  reGetBook,

  /// 对应 Android `AnalyzeRule.refreshTocUrl()`：使用当前详情地址重新加载详情。
  refreshTocUrl,
}

/// 由书源服务实现的请求前目录刷新动作，脚本桥不得自行递归业务服务。
typedef LegadoPreUpdateActionHandler = Future<void> Function(LegadoPreUpdateAction action);

/// 同时取消 QuickJS 和 M3 网络请求的组合控制器。
final class LegadoScriptCancellationController {
  /// 创建组合取消控制器。
  const LegadoScriptCancellationController({required this.js, required this.http});

  /// JavaScript 中断控制器。
  final JsCancellationController js;

  /// M3 HTTP 取消令牌。
  final HttpCancellationToken http;

  /// 同时取消脚本和仍在等待的宿主网络请求。
  void cancel() {
    js.cancel();
    http.cancel('JavaScript 执行已取消');
  }
}

/// 单次 Legado 脚本执行上下文。
///
/// 书籍和章节通过受控可变状态注入，以兼容 Android 规则脚本；上下文不得跨书源复用。
final class LegadoScriptContext implements JsHostBridgeContext {
  /// 创建脚本上下文。
  LegadoScriptContext({
    required this.source,
    required this.baseUri,
    this.book,
    this.chapter,
    this.result,
    this.key,
    this.page,
    this.nextChapterUrl,
    this.operation = LegadoScriptOperation.unknown,
    this.interactionPolicy = LegadoScriptInteractionPolicy.deny,
    LegadoScriptModelState? modelState,
    LegadoScriptExecutionState? executionState,
    this.preUpdateActionHandler,
    Map<String, String> variables = const <String, String>{},
    List<String>? bridgeCalls,
    this.httpCancellationToken,
  }) : executionState = executionState ??
           LegadoScriptExecutionState(
             modelState: modelState ?? LegadoScriptModelState(book: book, chapter: chapter),
             variables: variables,
           ),
       bridgeCalls = bridgeCalls ?? <String>[];

  /// 当前书源。
  final BookSource source;

  /// 当前规则解析基准地址。
  final Uri baseUri;

  /// 可选书籍。
  final Book? book;

  /// 可选章节。
  final BookChapter? chapter;

  /// 上一阶段结构化结果。
  final Object? result;

  /// 搜索关键字。
  final String? key;

  /// 当前页码。
  final int? page;

  /// 下一章节地址。
  final String? nextChapterUrl;

  /// 当前脚本所属业务操作，禁止底层桥通过猜测页面状态决定是否弹窗。
  final LegadoScriptOperation operation;

  /// 当前操作是否允许书源脚本打断用户；默认拒绝。
  final LegadoScriptInteractionPolicy interactionPolicy;

  /// 当前业务操作共享的模型和临时变量状态。
  final LegadoScriptExecutionState executionState;

  /// 仅在目录 `preUpdateJs` 执行期间提供的受控业务回调。
  final LegadoPreUpdateActionHandler? preUpdateActionHandler;

  /// 当前业务规则链共享的书籍和章节脚本状态。
  LegadoScriptModelState get modelState => executionState.modelState;

  /// 规则可变数据；键值更新只存在于当前业务上下文。
  Map<String, String> get variables => executionState.variables;

  /// 【FLUTTER_JS_COMPAT_LOG】当前规则链触达的宿主桥方法轨迹，仅保存方法名和参数类型。
  final List<String> bridgeCalls;

  /// 复用 M3 网络取消能力的令牌。
  final HttpCancellationToken? httpCancellationToken;

  /// 生成注入 JavaScript 的只读 DTO Map。
  Map<String, Object?> toBindings() {
    /// 当前规则步骤可见的书籍字段快照。
    final Map<String, Object?>? bookBinding = modelState.bookSnapshot();
    /// 当前规则步骤可见的章节字段快照。
    final Map<String, Object?>? chapterBinding = modelState.chapterSnapshot();
    return <String, Object?>{
      'baseUrl': baseUri.toString(),
      'key': key,
      'page': page,
      'nextChapterUrl': nextChapterUrl,
      'result': result,
      'src': result,
      'source': _sourceMap(source),
      'book': bookBinding,
      'chapter': chapterBinding,
      'title': chapterBinding?['title'],
      'variables': Map<String, String>.from(variables),
    };
  }

  /// 将书源转换为脚本可见 DTO。
  Map<String, Object?> _sourceMap(BookSource value) {
    return <String, Object?>{
      'bookSourceUrl': value.bookSourceUrl,
      'bookSourceName': value.bookSourceName,
      'bookSourceGroup': value.bookSourceGroup,
      'bookSourceType': value.bookSourceType,
      'enabled': value.enabled,
      'enabledCookieJar': value.enabledCookieJar,
      'header': value.header,
      'searchUrl': value.searchUrl,
      'exploreUrl': value.exploreUrl,
      'variable': variables['sourceVariable'] ?? '',
    };
  }

  /// 按 Android `AnalyzeRule.put` 优先级保存规则变量。
  void putRuleVariable(String key, String value) {
    if (chapter != null) {
      modelState.putVariable(bookModel: false, key: key, value: value);
    } else if (book != null) {
      modelState.putVariable(bookModel: true, key: key, value: value);
    } else {
      variables[key] = value;
    }
  }

  /// 按章节、书籍、临时规则数据和书源变量顺序读取规则变量。
  String getRuleVariable(String key) {
    if (key == 'bookName') {
      return modelState.fieldValue(bookModel: true, field: 'name')?.toString() ?? '';
    }
    if (key == 'title') {
      return modelState.fieldValue(bookModel: false, field: 'title')?.toString() ?? '';
    }
    if (chapter != null) {
      /// 当前章节变量。
      final String chapterValue = modelState.getVariable(bookModel: false, key: key);
      if (chapterValue.isNotEmpty) {
        return chapterValue;
      }
    }
    if (book != null) {
      /// 当前书籍变量。
      final String bookValue = modelState.getVariable(bookModel: true, key: key);
      if (bookValue.isNotEmpty) {
        return bookValue;
      }
    }
    /// 当前请求和解析链共享的临时规则变量。
    final String ruleValue = variables[key] ?? '';
    if (ruleValue.isNotEmpty) {
      return ruleValue;
    }
    /// 预载入的书源持久变量 JSON。
    final String sourceVariable = variables['sourceVariable'] ?? '';
    if (sourceVariable.trim().isEmpty) {
      return '';
    }
    try {
      /// 解码后的书源变量对象。
      final Object? decoded = jsonDecode(sourceVariable);
      if (decoded is Map && decoded[key] != null) {
        return decoded[key].toString();
      }
    } on FormatException {
      return '';
    }
    return '';
  }

}

/// 单次搜索、详情、目录或正文操作跨请求与解析阶段共享的脚本状态。
final class LegadoScriptExecutionState {
  /// 创建共享状态，并隔离调用方传入的初始临时变量。
  LegadoScriptExecutionState({
    required this.modelState,
    Map<String, String> variables = const <String, String>{},
  }) : variables = Map<String, String>.from(variables);

  /// 规则链共享的 Book/Chapter 模型状态。
  final LegadoScriptModelState modelState;

  /// URL、响应、登录检测和字段解析共享的临时规则变量。
  final Map<String, String> variables;
}

/// 单条规则链内可修改的 Android 兼容书籍和章节模型状态。
///
/// Flutter 领域模型保持不可变；脚本修改只在当前解析链共享，避免规则直接越过仓储写数据库。
final class LegadoScriptModelState {
  /// 从当前书籍和章节事实创建脚本状态。
  LegadoScriptModelState({Book? book, BookChapter? chapter})
    : _bookValues = _createBookValues(book),
      _chapterValues = _createChapterValues(chapter),
      _bookVariables = _decodeVariables(book?.variable),
      _chapterVariables = _decodeVariables(chapter?.variable);

  /// 可选书籍字段；键集合同时构成允许脚本回写的字段白名单。
  final Map<String, Object?>? _bookValues;

  /// 可选章节字段；键集合同时构成允许脚本回写的字段白名单。
  final Map<String, Object?>? _chapterValues;

  /// 从书籍 `variable` JSON 解码出的当前规则链变量。
  final Map<String, String> _bookVariables;

  /// 从章节 `variable` JSON 解码出的当前规则链变量。
  final Map<String, String> _chapterVariables;

  /// 返回隔离副本，防止 JS 绑定准备阶段直接持有内部书籍 Map。
  Map<String, Object?>? bookSnapshot() {
    /// 当前书籍脚本字段。
    final Map<String, Object?>? values = _bookValues;
    return values == null ? null : Map<String, Object?>.from(values);
  }

  /// 返回隔离副本，防止 JS 绑定准备阶段直接持有内部章节 Map。
  Map<String, Object?>? chapterSnapshot() {
    /// 当前章节脚本字段。
    final Map<String, Object?>? values = _chapterValues;
    return values == null ? null : Map<String, Object?>.from(values);
  }

  /// 读取书籍或章节的单个脚本变量；未配置时返回空字符串对齐 Android。
  String getVariable({required bool bookModel, required String key}) {
    /// 目标模型的变量 Map。
    final Map<String, String> variables = bookModel ? _bookVariables : _chapterVariables;
    return variables[key] ?? '';
  }

  /// 返回书籍或章节变量快照，供 `getVariableMap()` 构造 JavaScript Map。
  Map<String, String> variableSnapshot({required bool bookModel}) {
    /// 目标模型的变量 Map。
    final Map<String, String> variables = bookModel ? _bookVariables : _chapterVariables;
    return Map<String, String>.from(variables);
  }

  /// 读取当前规则链内已经应用回写的书籍或章节字段。
  Object? fieldValue({required bool bookModel, required String field}) {
    /// 目标模型的字段 Map。
    final Map<String, Object?>? values = bookModel ? _bookValues : _chapterValues;
    return values?[field];
  }

  /// 更新书籍或章节脚本变量，并同步刷新模型可见的 `variable` JSON 字段。
  String putVariable({required bool bookModel, required String key, required String value}) {
    /// 目标模型的变量 Map。
    final Map<String, String> variables = bookModel ? _bookVariables : _chapterVariables;
    /// 目标模型的字段 Map。
    final Map<String, Object?>? values = bookModel ? _bookValues : _chapterValues;
    variables[key] = value;
    if (values != null) {
      values['variable'] = jsonEncode(variables);
    }
    return value;
  }

  /// 回写白名单内的书籍或章节字段，并返回实际保存的值。
  Object? setField({required bool bookModel, required String field, required Object? value}) {
    /// 目标模型的字段 Map。
    final Map<String, Object?>? values = bookModel ? _bookValues : _chapterValues;
    if (values == null || !values.containsKey(field)) {
      throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '${bookModel ? 'book' : 'chapter'} 不允许修改字段 $field',
      );
    }
    values[field] = value;
    if (field == 'variable') {
      /// 与新 `variable` JSON 保持一致的目标变量 Map。
      final Map<String, String> variables = bookModel ? _bookVariables : _chapterVariables;
      variables
        ..clear()
        ..addAll(_decodeVariables(value?.toString()));
    }
    return value;
  }

  /// 把领域书籍转换为完整的 JSON 安全脚本字段集合。
  static Map<String, Object?>? _createBookValues(Book? value) {
    if (value == null) {
      return null;
    }
    return <String, Object?>{
      'bookUrl': value.bookUrl,
      'tocUrl': value.tocUrl,
      'origin': value.origin,
      'originName': value.originName,
      'name': value.name,
      'author': value.author,
      'kind': value.kind,
      'customTag': value.customTag,
      'coverUrl': value.coverUrl,
      'customCoverUrl': value.customCoverUrl,
      'intro': value.intro,
      'customIntro': value.customIntro,
      'remark': value.remark,
      'charset': value.charset,
      'type': value.type,
      'group': value.group,
      'latestChapterTitle': value.latestChapterTitle,
      'latestChapterTime': value.latestChapterTime,
      'lastCheckTime': value.lastCheckTime,
      'lastCheckCount': value.lastCheckCount,
      'totalChapterNum': value.totalChapterNum,
      'durChapterTitle': value.durChapterTitle,
      'durChapterIndex': value.durChapterIndex,
      'durChapterPos': value.durChapterPos,
      'durChapterTime': value.durChapterTime,
      'wordCount': value.wordCount,
      'canUpdate': value.canUpdate,
      'order': value.order,
      'originOrder': value.originOrder,
      'variable': value.variable,
      'imageStyle': value.readConfig?.imageStyle,
      'syncTime': value.syncTime,
    };
  }

  /// 把领域章节转换为完整的 JSON 安全脚本字段集合。
  static Map<String, Object?>? _createChapterValues(BookChapter? value) {
    if (value == null) {
      return null;
    }
    return <String, Object?>{
      'url': value.url,
      'title': value.title,
      'bookUrl': value.bookUrl,
      'index': value.index,
      'isVolume': value.isVolume,
      'baseUrl': value.baseUrl,
      'isVip': value.isVip,
      'isPay': value.isPay,
      'resourceUrl': value.resourceUrl,
      'tag': value.tag,
      'wordCount': value.wordCount,
      'start': value.start,
      'end': value.end,
      'startFragmentId': value.startFragmentId,
      'endFragmentId': value.endFragmentId,
      'variable': value.variable,
      'reviewImg': value.reviewImg,
    };
  }

  /// 宽容解析 Android 模型变量 JSON；损坏或非对象内容按空变量处理。
  static Map<String, String> _decodeVariables(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return <String, String>{};
    }
    try {
      /// 解码后的任意 JSON 值。
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return <String, String>{};
      }
      /// 只保留字符串键，并按 Android 字符串变量语义转换值。
      final Map<String, String> result = <String, String>{};
      decoded.forEach((Object? key, Object? value) {
        if (key is String && value != null) {
          result[key] = value.toString();
        }
      });
      return result;
    } on FormatException {
      return <String, String>{};
    }
  }
}
