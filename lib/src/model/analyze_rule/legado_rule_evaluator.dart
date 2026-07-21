import 'dart:convert';

import '../../api/js/js_engine.dart';
import '../../api/js/script_context.dart';
import 'legado_javascript_service.dart';
import 'standard_rule_engine.dart';

/// 按 Android `AnalyzeRule` 顺序串联普通选择器与 JavaScript 的异步规则执行器。
///
/// 纯普通规则仍交给 [StandardRuleEngine]；只有出现 `@js:`、`<js>` 或 `{{...}}`
/// 时才进入 QuickJS，避免改变 M3 已有规则的执行路径。
final class LegadoRuleEvaluator {
  /// 创建混合规则执行器。
  const LegadoRuleEvaluator(this._javaScriptService);

  /// M4 JavaScript 统一执行入口。
  final LegadoJavaScriptService _javaScriptService;

  /// M3 普通规则执行器。
  static const StandardRuleEngine _standardEngine = StandardRuleEngine();

  /// 判断规则是否包含需要 M4 处理的 JavaScript 语法。
  bool containsJavaScript(String? rule) {
    if (rule == null || rule.trim().isEmpty) {
      return false;
    }
    /// 小写规则文本，用于大小写不敏感地识别固定标记。
    final String normalized = rule.toLowerCase();
    return normalized.contains('@js:') ||
        normalized.contains('<js>') ||
        normalized.contains('{{') ||
        normalized.contains('@put:') ||
        normalized.contains('@get:');
  }

  /// 按列表语义执行规则并返回内部节点。
  Future<StandardRuleMatch<StandardRuleNode>> elements({
    required String? rule,
    required Object? input,
    required LegadoScriptContext context,
    JsCancellationToken? cancellationToken,
  }) async {
    if (!containsJavaScript(rule)) {
      return _standardEngine.elements(rule, input);
    }
    /// 依次执行普通规则段和脚本段后的结果。
    final Object? value = await _evaluateMixed(
      rule: rule ?? '',
      input: input,
      context: context,
      elementMode: true,
      cancellationToken: cancellationToken,
    );
    /// 将脚本列表或单值统一转换成规则节点。
    final Iterable<Object?> values = value is Iterable ? value.cast<Object?>() : <Object?>[value];
    return StandardRuleMatch<StandardRuleNode>(
      values
          .where((Object? item) => item is! JsUndefinedValue)
          .map((Object? item) => StandardRuleNode(item)),
    );
  }

  /// 按字符串列表语义执行规则。
  Future<StandardRuleMatch<String>> strings({
    required String? rule,
    required Object? input,
    required LegadoScriptContext context,
    JsCancellationToken? cancellationToken,
  }) async {
    if (rule == null || rule.trim().isEmpty) {
      return StandardRuleMatch<String>(const <String>[]);
    }
    if (!containsJavaScript(rule)) {
      return _standardEngine.strings(rule, input);
    }
    /// 依次执行普通规则段和脚本段后的结果。
    final Object? value = await _evaluateMixed(
      rule: rule,
      input: input,
      context: context,
      elementMode: false,
      cancellationToken: cancellationToken,
    );
    /// 保持脚本数组顺序的字符串结果。
    final Iterable<Object?> values = value is Iterable ? value.cast<Object?>() : <Object?>[value];
    return StandardRuleMatch<String>(
      values
          .where((Object? item) => item != null && item is! JsUndefinedValue)
          .map(_stringValue)
          .where((String item) => item.isNotEmpty),
    );
  }

  /// 按单字符串语义执行规则，空结果返回空字符串。
  Future<String> string({
    required String? rule,
    required Object? input,
    required LegadoScriptContext context,
    JsCancellationToken? cancellationToken,
  }) async {
    return (await strings(
          rule: rule,
          input: input,
          context: context,
          cancellationToken: cancellationToken,
        ))
        .firstOrNull ??
        '';
  }

  /// 执行内嵌表达式和顺序规则段，对齐 Android `AnalyzeRule.evalJS` 的 `result` 传递。
  Future<Object?> _evaluateMixed({
    required String rule,
    required Object? input,
    required LegadoScriptContext context,
    required bool elementMode,
    JsCancellationToken? cancellationToken,
  }) async {
    /// 移除并执行 `@put` 后的规则文本。
    final String putResolved = await _resolvePutRules(
      rule,
      input: input,
      context: context,
      cancellationToken: cancellationToken,
    );
    /// 当前规则是否使用 `@get` 组装字符串；Android 会把此类 SourceRule 切换为 Regex 文本模式。
    final bool hasGetTemplate = RegExp(
      r'@get:\{[^}]+?\}',
      caseSensitive: false,
    ).hasMatch(putResolved);
    /// 使用当前共享状态替换全部 `@get:{key}`。
    final String storedResolved = putResolved.replaceAllMapped(
      RegExp(r'@get:\{([^}]+?)\}', caseSensitive: false),
      (Match match) => context.getRuleVariable((match.group(1) ?? '').trim()),
    );
    /// 已执行 `{{...}}` 表达式替换的规则文本。
    final String embeddedResolved = await _resolveEmbeddedExpressions(
      storedResolved,
      input: input,
      context: context,
      cancellationToken: cancellationToken,
    );
    if ((storedResolved.contains('{{') || hasGetTemplate) &&
        !storedResolved.toLowerCase().contains('@js:') &&
        !storedResolved.toLowerCase().contains('<js>')) {
      return embeddedResolved;
    }
    /// 按原始先后顺序拆分的普通规则段和脚本段。
    final List<_LegadoRuleStage> stages = _splitStages(embeddedResolved);
    /// 当前阶段接收的上一步结果。
    Object? current = input;
    for (int index = 0; index < stages.length; index += 1) {
      /// 当前待执行规则段。
      final _LegadoRuleStage stage = stages[index];
      if (stage.javaScript) {
        current = await _evaluateJavaScript(
          script: stage.source,
          scriptName: 'rule-stage-${index + 1}',
          result: current,
          context: context,
          cancellationToken: cancellationToken,
        );
      } else if (elementMode && index == stages.length - 1) {
        current = _standardEngine
            .elements(stage.source, current)
            .values
            .map((StandardRuleNode node) => node.value)
            .toList(growable: false);
      } else {
        /// 当前普通规则段的全部字符串结果。
        final List<String> values = _standardEngine.strings(stage.source, current).values;
        current = values.length <= 1 ? (values.isEmpty ? '' : values.first) : values.join('\n');
      }
    }
    return current;
  }

  /// 执行 Android `@put:{key: rule}`，右侧规则始终读取当前页面根内容。
  Future<String> _resolvePutRules(
    String rule, {
    required Object? input,
    required LegadoScriptContext context,
    JsCancellationToken? cancellationToken,
  }) async {
    /// Android 同款的非嵌套 `@put` 对象匹配器。
    final RegExp putPattern = RegExp(r'@put:(\{[^}]+?\})', caseSensitive: false);
    /// 当前规则中全部待保存的变量规则。
    final List<MapEntry<String, String>> entries = <MapEntry<String, String>>[];
    for (final RegExpMatch match in putPattern.allMatches(rule)) {
      entries.addAll(_parsePutEntries(match.group(1) ?? '{}'));
    }
    /// Android `putRule` 使用 AnalyzeRule 根 content，而不是上一段的局部结果。
    final Object? rootInput = context.result ?? input;
    for (final MapEntry<String, String> entry in entries) {
      /// 右侧普通或混合规则解析得到的变量值。
      final String value = await string(
        rule: entry.value,
        input: rootInput,
        context: context,
        cancellationToken: cancellationToken,
      );
      context.putRuleVariable(entry.key, value);
    }
    return rule.replaceAll(putPattern, '');
  }

  /// 宽容解析严格 JSON及原生兼容的未加引号 `@put` 对象。
  List<MapEntry<String, String>> _parsePutEntries(String objectText) {
    /// 去除最外层花括号后的对象正文。
    final String body = objectText.length >= 2
        ? objectText.substring(1, objectText.length - 1)
        : '';
    /// 顶层逗号分隔后的键值片段。
    final List<String> fields = _splitTopLevel(body, ',');
    /// 保持书源声明顺序的变量规则。
    final List<MapEntry<String, String>> result = <MapEntry<String, String>>[];
    for (final String field in fields) {
      /// 当前字段顶层冒号位置。
      final int separator = _topLevelSeparator(field, ':');
      if (separator <= 0) {
        continue;
      }
      /// 去引号后的变量键。
      final String key = _decodeRuleToken(field.substring(0, separator)).trim();
      /// 保留选择器语法的变量值规则。
      final String value = _decodeRuleToken(field.substring(separator + 1)).trim();
      if (key.isNotEmpty && value.isNotEmpty) {
        result.add(MapEntry<String, String>(key, value));
      }
    }
    return result;
  }

  /// 在引号和括号外按指定字符切分文本。
  List<String> _splitTopLevel(String value, String separator) {
    /// 已切分片段。
    final List<String> result = <String>[];
    /// 当前片段起点。
    int start = 0;
    /// 当前字符串引号。
    String? quote;
    /// 上一字符是否为转义符。
    bool escaped = false;
    /// 圆括号和方括号总层级。
    int depth = 0;
    for (int index = 0; index < value.length; index += 1) {
      /// 当前字符。
      final String character = value[index];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (character == '\\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (character == quote) {
          quote = null;
        }
        continue;
      }
      if (character == '"' || character == "'") {
        quote = character;
        continue;
      }
      if (character == '(' || character == '[') {
        depth += 1;
      } else if ((character == ')' || character == ']') && depth > 0) {
        depth -= 1;
      } else if (depth == 0 && character == separator) {
        result.add(value.substring(start, index));
        start = index + 1;
      }
    }
    result.add(value.substring(start));
    return result;
  }

  /// 查找引号和括号外的首个字段分隔符。
  int _topLevelSeparator(String value, String separator) {
    /// 复用顶层切分后第一段长度，避免为冒号复制扫描状态机。
    final List<String> parts = _splitTopLevel(value, separator);
    return parts.length <= 1 ? -1 : parts.first.length;
  }

  /// 解码带引号的 JSON 字符串；未加引号的选择器原样返回。
  String _decodeRuleToken(String value) {
    /// 去除首尾空白后的 token。
    final String trimmed = value.trim();
    if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
      try {
        return jsonDecode(trimmed).toString();
      } on FormatException {
        return trimmed.substring(1, trimmed.length - 1);
      }
    }
    if (trimmed.length >= 2 && trimmed.startsWith("'") && trimmed.endsWith("'")) {
      return trimmed.substring(1, trimmed.length - 1);
    }
    return trimmed;
  }

  /// 顺序执行规则中的全部 `{{...}}` 表达式并替换原位置。
  Future<String> _resolveEmbeddedExpressions(
    String rule, {
    required Object? input,
    required LegadoScriptContext context,
    JsCancellationToken? cancellationToken,
  }) async {
    /// 内嵌 JavaScript 表达式匹配器。
    final RegExp expressionPattern = RegExp(r'\{\{([\s\S]*?)\}\}');
    /// 保留尚未处理部分的起点。
    int cursor = 0;
    /// 按原始顺序构造替换结果。
    final StringBuffer buffer = StringBuffer();
    for (final RegExpMatch match in expressionPattern.allMatches(rule)) {
      buffer.write(rule.substring(cursor, match.start));
      /// 当前内嵌表达式正文。
      final String expression = match.group(1) ?? '';
      /// Android `isRule` 识别出的内嵌普通规则直接读取当前输入，其余表达式才交给 JavaScript。
      final Object? value = _isEmbeddedStandardRule(expression)
          ? _standardEngine.string(expression, input)
          : await _evaluateJavaScript(
              script: expression,
              scriptName: 'embedded-expression',
              result: input,
              context: context,
              cancellationToken: cancellationToken,
            );
      buffer.write(_stringValue(value));
      cursor = match.end;
    }
    buffer.write(rule.substring(cursor));
    return buffer.toString();
  }

  /// 对齐 Android `AnalyzeRule.isRule`，识别 `{{...}}` 中嵌套的普通规则。
  bool _isEmbeddedStandardRule(String expression) {
    /// 去除首尾空白后的内嵌规则。
    final String normalized = expression.trim();
    return normalized.startsWith('@') ||
        normalized.startsWith(r'$.') ||
        normalized.startsWith(r'$[') ||
        normalized.startsWith('//');
  }

  /// 使用复制后的运行上下文执行一段脚本，并把脚本变量写回同一业务上下文。
  Future<Object?> _evaluateJavaScript({
    required String script,
    required String scriptName,
    required Object? result,
    required LegadoScriptContext context,
    JsCancellationToken? cancellationToken,
  }) async {
    /// 当前脚本独占且携带上一步 `result/src` 的运行上下文。
    final LegadoScriptContext runtimeContext = LegadoScriptContext(
      source: context.source,
      baseUri: context.baseUri,
      book: context.book,
      chapter: context.chapter,
      result: result,
      key: context.key,
      page: context.page,
      nextChapterUrl: context.nextChapterUrl,
      operation: context.operation,
      interactionPolicy: context.interactionPolicy,
      executionState: context.executionState,
      preUpdateActionHandler: context.preUpdateActionHandler,
      bridgeCalls: context.bridgeCalls,
      httpCancellationToken: context.httpCancellationToken,
    );
    /// 当前脚本返回的结构化结果。
    final JsBridgeValue value = await _javaScriptService.evaluate(
      scriptName: '${context.source.bookSourceName}/$scriptName',
      script: script,
      context: runtimeContext,
      cancellationToken: cancellationToken,
    );
    return value;
  }

  /// 将混合规则拆成普通规则段和闭合/尾部 JavaScript 段。
  List<_LegadoRuleStage> _splitStages(String rule) {
    /// 已拆分规则段。
    final List<_LegadoRuleStage> stages = <_LegadoRuleStage>[];
    /// 闭合 `<js>...</js>` 匹配器。
    final RegExp blockPattern = RegExp(
      r'<js>([\s\S]*?)</js>',
      caseSensitive: false,
    );
    /// 尚未加入结果的文本起点。
    int cursor = 0;
    for (final RegExpMatch match in blockPattern.allMatches(rule)) {
      _appendPlainOrTailJavaScript(stages, rule.substring(cursor, match.start));
      stages.add(_LegadoRuleStage(javaScript: true, source: match.group(1) ?? ''));
      cursor = match.end;
    }
    _appendPlainOrTailJavaScript(stages, rule.substring(cursor));
    if (stages.isEmpty) {
      stages.add(_LegadoRuleStage(javaScript: false, source: rule));
    }
    return stages;
  }

  /// 拆分普通规则文本中可能存在的尾部 `@js:` 规则。
  void _appendPlainOrTailJavaScript(
    List<_LegadoRuleStage> stages,
    String text,
  ) {
    /// `@js:` 标记位置。
    final RegExpMatch? marker = RegExp(r'@js:', caseSensitive: false).firstMatch(text);
    if (marker == null) {
      if (text.trim().isNotEmpty) {
        stages.add(_LegadoRuleStage(javaScript: false, source: text.trim()));
      }
      return;
    }
    /// 标记之前的普通规则。
    final String prefix = text.substring(0, marker.start).trim();
    if (prefix.isNotEmpty) {
      stages.add(_LegadoRuleStage(javaScript: false, source: prefix));
    }
    /// 标记之后直到规则结束的脚本。
    final String script = text.substring(marker.end).trim();
    stages.add(_LegadoRuleStage(javaScript: true, source: script));
  }

  /// 将脚本桥值转换为 Android 规则拼接使用的字符串。
  String _stringValue(Object? value) {
    if (value == null || value is JsUndefinedValue || value is JsArrayHoleValue) {
      return '';
    }
    if (value is String) {
      return value;
    }
    if (value is double && value.isFinite && value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    if (value is Map || value is List) {
      return jsonEncode(value);
    }
    return value.toString();
  }
}

/// 混合规则中的一个顺序执行阶段。
final class _LegadoRuleStage {
  /// 创建不可变规则阶段。
  const _LegadoRuleStage({required this.javaScript, required this.source});

  /// 是否为 JavaScript 阶段。
  final bool javaScript;

  /// 普通规则或 JavaScript 正文。
  final String source;
}
