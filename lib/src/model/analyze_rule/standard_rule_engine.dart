import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:json_path/json_path.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

/// 普通规则语法或执行失败；与合法规则的空匹配严格区分。
final class StandardRuleException implements Exception {
  /// 创建普通规则异常。
  const StandardRuleException(this.message, {this.rule});

  /// 不包含被解析正文的错误说明。
  final String message;

  /// 可选规则文本，便于书源作者定位问题。
  final String? rule;

  @override
  String toString() => 'StandardRuleException($message)';
}

/// 普通规则匹配结果；空列表代表规则合法但没有匹配。
final class StandardRuleMatch<T> {
  /// 创建不可变匹配结果。
  StandardRuleMatch(Iterable<T> values)
    : values = List<T>.unmodifiable(values);

  /// 按规则顺序排列的匹配值。
  final List<T> values;

  /// 是否没有匹配到任何值。
  bool get isEmpty => values.isEmpty;

  /// 首个匹配值；空匹配返回 `null`。
  T? get firstOrNull => values.isEmpty ? null : values.first;
}

/// 普通规则内部节点，可保存 JSON 值或 HTML 节点。
final class StandardRuleNode {
  /// 创建内部规则节点。
  const StandardRuleNode(this.value);

  /// JSON 值、HTML 节点或纯文本。
  final Object? value;
}

/// 非 JavaScript 普通规则引擎，支持 JSONPath、XPath、CSS、Regex 和字符串替换。
final class StandardRuleEngine {
  /// 创建规则引擎。
  const StandardRuleEngine();

  /// 将文档按列表规则转换为内部节点。
  StandardRuleMatch<StandardRuleNode> elements(String? rule, Object? input) {
    if (rule == null || rule.trim().isEmpty) {
      return StandardRuleMatch<StandardRuleNode>(<StandardRuleNode>[
        StandardRuleNode(input),
      ]);
    }
    _rejectJavaScript(rule);
    try {
      /// 去除列表反转与兼容前缀后的规则。
      final String normalized = rule.startsWith('-') || rule.startsWith('+')
          ? rule.substring(1)
          : rule;
      /// 原始匹配值。
      final List<Object?> values = _evaluate(normalized, input, elementMode: true);
      return StandardRuleMatch<StandardRuleNode>(
        values.map((Object? value) => StandardRuleNode(value)),
      );
    } on StandardRuleException {
      rethrow;
    } catch (error) {
      throw StandardRuleException('列表规则执行失败：$error', rule: rule);
    }
  }

  /// 获取规则的全部字符串结果。
  StandardRuleMatch<String> strings(String? rule, Object? input) {
    if (rule == null || rule.trim().isEmpty) {
      return StandardRuleMatch<String>(const <String>[]);
    }
    _rejectJavaScript(rule);
    try {
      /// 替换语法分段。
      final List<String> replacementParts = rule.split('##');
      /// 选择器主体。
      final String selector = replacementParts.first;
      /// 选择器匹配值。
      List<String> values = _evaluate(selector, input, elementMode: false)
          .map(_stringValue)
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
      if (replacementParts.length >= 2 && replacementParts[1].isNotEmpty) {
        /// 替换正则。
        final RegExp pattern = RegExp(replacementParts[1], multiLine: true);
        /// 替换文本。
        final String replacement = replacementParts.length >= 3
            ? replacementParts[2]
            : '';
        /// Android 四段形式使用 replaceFirst，其余使用 replaceAll。
        final bool replaceFirstOnly = replacementParts.length >= 4;
        values = values
            .map(
              (String value) => replaceFirstOnly
                  ? value.replaceFirst(pattern, replacement)
                  : value.replaceAll(pattern, replacement),
            )
            .toList(growable: false);
      }
      return StandardRuleMatch<String>(values);
    } on StandardRuleException {
      rethrow;
    } on FormatException catch (error) {
      throw StandardRuleException('规则格式无效：${error.message}', rule: rule);
    } catch (error) {
      throw StandardRuleException('字符串规则执行失败：$error', rule: rule);
    }
  }

  /// 获取首个字符串结果，空匹配返回空字符串以兼容 Android 字段赋值。
  String string(String? rule, Object? input) {
    return strings(rule, input).firstOrNull ?? '';
  }

  /// 计算规则运算符与具体选择器。
  List<Object?> _evaluate(String rule, Object? input, {required bool elementMode}) {
    /// `||` 返回第一组非空结果。
    final List<String> alternatives = _splitOperator(rule, '||');
    if (alternatives.length > 1) {
      for (final String alternative in alternatives) {
        /// 当前候选结果。
        final List<Object?> values = _evaluate(alternative, input, elementMode: elementMode);
        if (values.isNotEmpty) {
          return values;
        }
      }
      return <Object?>[];
    }
    /// `%%` 按位置交错各组结果。
    final List<String> interleavedRules = _splitOperator(rule, '%%');
    if (interleavedRules.length > 1) {
      /// 每个子规则结果。
      final List<List<Object?>> groups = interleavedRules
          .map((String part) => _evaluate(part, input, elementMode: elementMode))
          .toList(growable: false);
      /// 最大结果长度。
      final int maxLength = groups.fold<int>(
        0,
        (int current, List<Object?> group) => group.length > current ? group.length : current,
      );
      /// 交错结果。
      final List<Object?> result = <Object?>[];
      for (int index = 0; index < maxLength; index += 1) {
        for (final List<Object?> group in groups) {
          if (index < group.length) {
            result.add(group[index]);
          }
        }
      }
      return result;
    }
    /// `&&` 顺序拼接全部结果。
    final List<String> combinedRules = _splitOperator(rule, '&&');
    if (combinedRules.length > 1) {
      return combinedRules
          .expand((String part) => _evaluate(part, input, elementMode: elementMode))
          .toList(growable: false);
    }
    return _evaluateSingle(rule.trim(), input, elementMode: elementMode);
  }

  /// 执行单个选择器。
  List<Object?> _evaluateSingle(String rule, Object? input, {required bool elementMode}) {
    if (rule.isEmpty) {
      return <Object?>[input];
    }
    if (rule.startsWith('@Json:')) {
      return _jsonPath(rule.substring(6), input);
    }
    if (rule.startsWith(r'$.') || rule.startsWith(r'$[') || _isJsonInput(input)) {
      return _jsonPath(rule, input);
    }
    if (rule.startsWith('@XPath:')) {
      return _xpath(rule.substring(7), input, elementMode: elementMode);
    }
    if (rule.startsWith('/')) {
      return _xpath(rule, input, elementMode: elementMode);
    }
    if (rule.startsWith(':')) {
      return _regex(rule.substring(1), input, elementMode: elementMode);
    }
    if (rule.startsWith('@CSS:')) {
      return _css(rule.substring(5), input, elementMode: elementMode);
    }
    return _css(rule, input, elementMode: elementMode);
  }

  /// 执行 JSONPath。
  List<Object?> _jsonPath(String rule, Object? input) {
    /// JSON 根对象。
    final Object? root = input is String ? jsonDecode(input) : input;
    /// 符合 RFC 9535 的 JSONPath。
    /// 去除空白的原始路径。
    final String trimmed = rule.trim();
    /// Android JSON 字段常省略根 `$`，此处补成 JSONPath。
    final String path = trimmed.isEmpty
        ? r'$'
        : (trimmed.startsWith(r'$') ? trimmed : r'$.' + trimmed);
    return JsonPath(path).readValues(root).toList(growable: false);
  }

  /// 执行 CSS 选择器及 `@text/@ownText/@html/@all/@属性` 取值。
  List<Object?> _css(String rule, Object? input, {required bool elementMode}) {
    /// CSS 查询根节点。
    final dom.Element root = _htmlRoot(input);
    /// 原生 Legado 默认规则按 `@` 串联选择器，字符串规则最后一段才表示取值方式。
    final List<String> chainParts = _splitOperator(rule, '@')
        .map((String part) => part.trim())
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);
    if (chainParts.isEmpty) {
      return elementMode ? <Object?>[root] : <Object?>[root.text];
    }
    /// 单段字符串规则是否表示从当前节点直接取文本或属性。
    final bool singleCurrentValueRule = !elementMode &&
        chainParts.length == 1 &&
        _isCurrentCssValueRule(chainParts.first);
    /// 当前规则用于逐层查询的选择器链。
    final List<String> selectorParts = elementMode
        ? chainParts
        : (singleCurrentValueRule
              ? const <String>[]
              : (chainParts.length > 1
              ? chainParts.sublist(0, chainParts.length - 1)
              : <String>[chainParts.first]));
    /// 当前规则最终需要提取的字段；元素模式不读取该字段。
    final String extractor = elementMode
        ? 'text'
        : (singleCurrentValueRule
              ? chainParts.first
              : (chainParts.length > 1 ? chainParts.last : 'text'));
    /// 按 Legado `@` 链式语义逐层命中的元素。
    final List<dom.Element> elements = _selectCssElementChain(root, selectorParts);
    if (elementMode) {
      return elements;
    }
    return elements
        .map((dom.Element element) => _extractCssValue(element, extractor))
        .toList(growable: false);
  }

  /// 判断单段字符串规则是否应按当前元素取值，而不是按 CSS 选择器查询子节点。
  bool _isCurrentCssValueRule(String rule) {
    /// 去除首尾空白后的取值规则。
    final String trimmed = rule.trim();
    return trimmed == 'text' ||
        trimmed == 'textNodes' ||
        trimmed == 'ownText' ||
        trimmed == 'html' ||
        trimmed == 'all' ||
        trimmed == 'href' ||
        trimmed == 'src' ||
        trimmed == 'content' ||
        trimmed == 'value' ||
        trimmed == 'title' ||
        trimmed == 'alt' ||
        trimmed.startsWith('abs:');
  }

  /// 按原生 Legado `@` 链式选择语义逐层查询元素。
  List<dom.Element> _selectCssElementChain(dom.Element root, List<String> selectorParts) {
    /// 当前层级的查询根集合。
    List<dom.Element> currentRoots = <dom.Element>[root];
    for (final String selectorPart in selectorParts) {
      /// 当前选择器在所有上层节点内命中的下一层元素。
      final List<dom.Element> nextRoots = <dom.Element>[];
      for (final dom.Element currentRoot in currentRoots) {
        nextRoots.addAll(_selectCssElements(currentRoot, selectorPart));
      }
      currentRoots = nextRoots;
      if (currentRoots.isEmpty) {
        break;
      }
    }
    return currentRoots;
  }

  /// 在单个根元素内执行一次 CSS 或 Legado 兼容选择器。
  List<dom.Element> _selectCssElements(dom.Element root, String selector) {
    /// 【原生规则兼容】解析 jsoup 文本伪选择器与 Legado 尾部索引。
    final _CompatibleCssSelector compatibleSelector = _parseCompatibleCssSelector(
      selector,
    );
    /// 标准 CSS 初始命中元素。
    List<dom.Element> elements = compatibleSelector.selector.isEmpty
        ? <dom.Element>[root]
        : root.querySelectorAll(compatibleSelector.selector);
    /// 【原生规则兼容】标准 CSS 查询完成后执行 jsoup 文本条件筛选。
    for (final _CssTextFilter filter in compatibleSelector.textFilters) {
      elements = elements
          .where((dom.Element element) => filter.matches(element))
          .toList(growable: false);
    }
    /// 【原生规则兼容】最后按 Legado `.0`、`.-1` 或 `!0` 规则筛选元素。
    elements = _applyLegacyIndexes(elements, compatibleSelector.indexRule);
    return elements;
  }

  /// 解析 Flutter 标准 CSS 不支持的原生 jsoup 文本伪选择器和 Legado 索引后缀。
  _CompatibleCssSelector _parseCompatibleCssSelector(String selector) {
    /// 去除首尾空白后的原始选择器。
    String standardSelector = selector.trim();
    /// 【原生规则兼容】选择器末尾的元素索引规则。
    _LegacyIndexRule? indexRule;
    /// `.0`、`.-1`、`.0:3` 与 `!0` 是原生 Legado 的列表筛选语法。
    final RegExpMatch? indexMatch = RegExp(
      r'([.!])(-?\d+(?::-?\d+(?::-?\d+)?)?)$',
    ).firstMatch(standardSelector);
    if (indexMatch != null) {
      indexRule = _LegacyIndexRule(
        exclude: indexMatch.group(1) == '!',
        expression: indexMatch.group(2) ?? '',
      );
      standardSelector = standardSelector.substring(0, indexMatch.start).trim();
    }

    /// 【原生规则兼容】从选择器中提取的 jsoup 文本筛选条件。
    final List<_CssTextFilter> textFilters = <_CssTextFilter>[];
    /// jsoup 支持但 `package:html` 不支持的 `:contains` 与 `:containsOwn`。
    final RegExp textPseudo = RegExp(
      r''':(containsOwn|contains)\(\s*(['"]?)(.*?)\2\s*\)''',
      caseSensitive: false,
    );
    standardSelector = standardSelector.replaceAllMapped(textPseudo, (Match match) {
      textFilters.add(
        _CssTextFilter(
          ownText: match.group(1)?.toLowerCase() == 'containsown',
          expectedText: match.group(3) ?? '',
        ),
      );
      return '';
    });

    /// 【原生规则兼容】原生默认规则常用的快捷选择器前缀。
    standardSelector = _normalizeLegacySelectorPrefix(standardSelector.trim());
    return _CompatibleCssSelector(
      selector: standardSelector,
      textFilters: textFilters,
      indexRule: indexRule,
    );
  }

  /// 将原生默认规则的 `class/tag/id` 快捷写法转换为标准 CSS。
  String _normalizeLegacySelectorPrefix(String selector) {
    if (selector.startsWith('class.')) {
      return '.${selector.substring(6)}';
    }
    if (selector.startsWith('tag.')) {
      return selector.substring(4);
    }
    if (selector.startsWith('id.')) {
      return '#${selector.substring(3)}';
    }
    return selector;
  }

  /// 按原生 Legado 的尾部索引规则选择或排除元素。
  List<dom.Element> _applyLegacyIndexes(
    List<dom.Element> elements,
    _LegacyIndexRule? indexRule,
  ) {
    if (indexRule == null || indexRule.expression.isEmpty || elements.isEmpty) {
      return elements;
    }
    /// 索引表达式各段，分别对应开始、结束和步长。
    final List<int> values = indexRule.expression
        .split(':')
        .map(int.parse)
        .toList(growable: false);
    /// 规范化负数索引，使 `-1` 指向最后一个元素。
    int normalize(int value) => value < 0 ? elements.length + value : value;
    /// 最终需要选择或排除的索引集合。
    final Set<int> selectedIndexes = <int>{};
    if (values.length == 1) {
      selectedIndexes.add(normalize(values.first));
    } else {
      /// 区间开始索引。
      final int normalizedStart = normalize(values[0]);
      final int start = normalizedStart < 0
          ? 0
          : (normalizedStart >= elements.length ? elements.length - 1 : normalizedStart);
      /// 区间结束索引；原生区间包含结束位置。
      final int normalizedEnd = normalize(values[1]);
      final int end = normalizedEnd < 0
          ? 0
          : (normalizedEnd >= elements.length ? elements.length - 1 : normalizedEnd);
      /// 区间步长，非法或零步长回退为一。
      final int rawStep = values.length >= 3 ? values[2].abs() : 1;
      final int step = rawStep == 0 ? 1 : rawStep;
      if (start <= end) {
        for (int index = start; index <= end; index += step) {
          selectedIndexes.add(index);
        }
      } else {
        for (int index = start; index >= end; index -= step) {
          selectedIndexes.add(index);
        }
      }
    }
    /// 按原始顺序保存完成筛选的元素。
    final List<dom.Element> result = <dom.Element>[];
    for (int index = 0; index < elements.length; index += 1) {
      /// 当前元素是否位于规则指定的索引集合中。
      final bool selected = selectedIndexes.contains(index);
      if (indexRule.exclude != selected) {
        result.add(elements[index]);
      }
    }
    return result;
  }

  /// 执行 XPath。
  List<Object?> _xpath(String rule, Object? input, {required bool elementMode}) {
    /// 可查询 HTML 文本。
    final String html = _htmlString(input);
    /// XPath 查询结果。
    final result = HtmlXPath.html(html).query(rule);
    if (result.attrs.any((String? value) => value != null)) {
      return result.attrs.whereType<String>().toList(growable: false);
    }
    if (elementMode) {
      return result.nodes.map((node) => node.node).toList(growable: false);
    }
    return result.nodes.map((node) => node.text ?? '').toList(growable: false);
  }

  /// 执行正则；列表模式返回完整匹配，字符串模式优先返回捕获组。
  List<Object?> _regex(String rule, Object? input, {required bool elementMode}) {
    /// 输入文本。
    final String text = _stringValue(input);
    /// 正则对象。
    final RegExp expression = RegExp(rule, multiLine: true);
    /// 结果。
    final List<Object?> values = <Object?>[];
    for (final RegExpMatch match in expression.allMatches(text)) {
      if (elementMode || match.groupCount == 0) {
        values.add(match.group(0) ?? '');
      } else {
        for (int group = 1; group <= match.groupCount; group += 1) {
          values.add(match.group(group) ?? '');
        }
      }
    }
    return values;
  }

  /// 提取 CSS 元素值。
  Object? _extractCssValue(dom.Element element, String extractor) {
    return switch (extractor) {
      'text' => element.text,
      'textNodes' => element.nodes
          .whereType<dom.Text>()
          .map((dom.Text node) => node.data.trim())
          .where((String text) => text.isNotEmpty)
          .join('\n'),
      'ownText' => element.nodes
          .whereType<dom.Text>()
          .map((dom.Text node) => node.data)
          .join(),
      'html' => element.innerHtml,
      'all' => element.outerHtml,
      _ => element.attributes[extractor],
    };
  }

  /// 将输入转换为 HTML 查询根元素。
  dom.Element _htmlRoot(Object? input) {
    if (input is dom.Element) {
      return input;
    }
    if (input is dom.Document) {
      return input.documentElement ?? dom.Element.tag('html');
    }
    /// 解析后的文档。
    final dom.Document document = html_parser.parse(_htmlString(input));
    return document.documentElement ?? dom.Element.tag('html');
  }

  /// 将内部输入转换为 HTML 文本。
  String _htmlString(Object? input) {
    if (input is dom.Element) {
      return input.outerHtml;
    }
    if (input is dom.Document) {
      return input.outerHtml;
    }
    return input?.toString() ?? '';
  }

  /// 将任意匹配值转换为字段字符串。
  String _stringValue(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is dom.Element) {
      return value.outerHtml;
    }
    if (value is dom.Node) {
      return value.text ?? '';
    }
    if (value is Map || value is List) {
      return jsonEncode(value);
    }
    return value.toString();
  }

  /// 判断输入是否已经是 JSON 结构。
  bool _isJsonInput(Object? input) {
    return input is Map || input is List;
  }

  /// 【原生规则兼容】只在引号、圆括号和方括号之外切分组合运算符。
  List<String> _splitOperator(String rule, String operator) {
    if (!rule.contains(operator)) {
      return <String>[rule];
    }
    /// 已完成切分的规则片段。
    final List<String> parts = <String>[];
    /// 当前片段起始位置。
    int partStart = 0;
    /// 当前未闭合圆括号层级。
    int parenthesisDepth = 0;
    /// 当前未闭合方括号层级。
    int bracketDepth = 0;
    /// 当前字符串引号；空值表示不在字符串中。
    String? quote;
    /// 上一个字符是否为转义符。
    bool escaped = false;
    for (int index = 0; index < rule.length; index += 1) {
      /// 当前扫描字符。
      final String character = rule[index];
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
      if (character == "'" || character == '"') {
        quote = character;
        continue;
      }
      if (character == '(') {
        parenthesisDepth += 1;
        continue;
      }
      if (character == ')') {
        if (parenthesisDepth > 0) {
          parenthesisDepth -= 1;
        }
        continue;
      }
      if (character == '[') {
        bracketDepth += 1;
        continue;
      }
      if (character == ']') {
        if (bracketDepth > 0) {
          bracketDepth -= 1;
        }
        continue;
      }
      if (parenthesisDepth == 0 &&
          bracketDepth == 0 &&
          rule.startsWith(operator, index)) {
        parts.add(rule.substring(partStart, index));
        index += operator.length - 1;
        partStart = index + 1;
      }
    }
    if (partStart == 0) {
      return <String>[rule];
    }
    parts.add(rule.substring(partStart));
    return parts;
  }

  /// 拒绝 JavaScript 规则，确保 M3 不伪装兼容。
  void _rejectJavaScript(String rule) {
    if (rule.contains('@js:') ||
        rule.contains('<js>') ||
        rule.contains('</js>') ||
        rule.contains('{{')) {
      throw StandardRuleException('规则包含 JavaScript，必须进入 M4', rule: rule);
    }
  }
}

/// 【原生规则兼容】转换为标准 CSS 后的选择器及其后置筛选条件。
final class _CompatibleCssSelector {
  /// 创建不可变兼容选择器。
  const _CompatibleCssSelector({
    required this.selector,
    required this.textFilters,
    required this.indexRule,
  });

  /// 可直接交给 `package:html` 的标准 CSS 选择器。
  final String selector;

  /// 需要在标准 CSS 查询后执行的 jsoup 文本筛选条件。
  final List<_CssTextFilter> textFilters;

  /// 可选的 Legado 元素索引规则。
  final _LegacyIndexRule? indexRule;
}

/// 【原生规则兼容】jsoup `:contains` 或 `:containsOwn` 的后置筛选条件。
final class _CssTextFilter {
  /// 创建文本筛选条件。
  const _CssTextFilter({required this.ownText, required this.expectedText});

  /// 是否只匹配当前元素自身的文本节点。
  final bool ownText;

  /// 需要包含的文本。
  final String expectedText;

  /// 判断当前元素是否满足原生 jsoup 文本选择条件。
  bool matches(dom.Element element) {
    /// 根据规则选择完整文本或当前元素直属文本。
    final String sourceText = ownText
        ? element.nodes.whereType<dom.Text>().map((dom.Text node) => node.data).join()
        : element.text;
    /// jsoup 的文本包含选择器按不区分大小写方式匹配。
    final String normalizedSourceText = sourceText.toLowerCase();
    /// 与 jsoup 使用相同大小写规则的目标文本。
    final String normalizedExpectedText = expectedText.toLowerCase();
    return normalizedSourceText.contains(normalizedExpectedText);
  }
}

/// 【原生规则兼容】Legado 选择器尾部的选择或排除索引规则。
final class _LegacyIndexRule {
  /// 创建元素索引规则。
  const _LegacyIndexRule({required this.exclude, required this.expression});

  /// 为 `true` 时排除指定元素，为 `false` 时只保留指定元素。
  final bool exclude;

  /// 原始索引或闭区间表达式，例如 `0`、`-1`、`0:3:2`。
  final String expression;
}
