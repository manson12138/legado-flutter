import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../http/http_contract.dart';
import 'js_engine.dart';

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
/// 模型以只读 DTO 注入，只有 [variables] 允许通过 `java.put/get` 修改；上下文不得跨书源复用。
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
    Map<String, String> variables = const <String, String>{},
    List<String>? bridgeCalls,
    this.httpCancellationToken,
  }) : variables = Map<String, String>.from(variables),
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

  /// 规则可变数据；键值更新只存在于当前业务上下文。
  final Map<String, String> variables;

  /// 【FLUTTER_JS_COMPAT_LOG】当前规则链触达的宿主桥方法轨迹，仅保存方法名和参数类型。
  final List<String> bridgeCalls;

  /// 复用 M3 网络取消能力的令牌。
  final HttpCancellationToken? httpCancellationToken;

  /// 生成注入 JavaScript 的只读 DTO Map。
  Map<String, Object?> toBindings() {
    return <String, Object?>{
      'baseUrl': baseUri.toString(),
      'key': key,
      'page': page,
      'nextChapterUrl': nextChapterUrl,
      'result': result,
      'src': result,
      'source': _sourceMap(source),
      'book': _bookMap(book),
      'chapter': _chapterMap(chapter),
      'title': chapter?.title,
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

  /// 将可选书籍转换为脚本可见 DTO。
  Map<String, Object?>? _bookMap(Book? value) {
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
      'coverUrl': value.coverUrl,
      'intro': value.intro,
      'type': value.type,
      'latestChapterTitle': value.latestChapterTitle,
      'wordCount': value.wordCount,
      'variable': value.variable,
    };
  }

  /// 将可选章节转换为脚本可见 DTO。
  Map<String, Object?>? _chapterMap(BookChapter? value) {
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
      'tag': value.tag,
      'wordCount': value.wordCount,
      'variable': value.variable,
    };
  }
}
