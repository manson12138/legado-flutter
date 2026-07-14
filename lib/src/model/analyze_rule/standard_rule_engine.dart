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
    /// 选择器与取值方式。
    final _CssRule parsed = _parseCssRule(rule);
    /// CSS 查询根节点。
    final dom.Element root = _htmlRoot(input);
    /// 命中的元素。
    final List<dom.Element> elements = parsed.selector.isEmpty
        ? <dom.Element>[root]
        : root.querySelectorAll(parsed.selector);
    if (elementMode) {
      return elements;
    }
    return elements
        .map((dom.Element element) => _extractCssValue(element, parsed.extractor))
        .toList(growable: false);
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

  /// 解析 CSS 规则最后一个 `@` 取值后缀。
  _CssRule _parseCssRule(String rule) {
    /// 常用取值后缀匹配。
    final RegExpMatch? known = RegExp(r'@(text|ownText|html|all)$').firstMatch(rule);
    if (known != null) {
      return _CssRule(
        selector: rule.substring(0, known.start),
        extractor: known.group(1) ?? 'text',
      );
    }
    /// 最后一个属性取值分隔符。
    final int attributeAt = rule.lastIndexOf('@');
    if (attributeAt >= 0) {
      return _CssRule(
        selector: rule.substring(0, attributeAt),
        extractor: rule.substring(attributeAt + 1),
      );
    }
    return _CssRule(selector: rule, extractor: 'text');
  }

  /// 提取 CSS 元素值。
  Object? _extractCssValue(dom.Element element, String extractor) {
    return switch (extractor) {
      'text' => element.text,
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

  /// 在不理解括号与引号的前提下仅切分顶层兼容运算符。
  ///
  /// Android 历史规则的运算符没有统一转义协议；M3 先保留常见直接写法，包含同文字面量
  /// 的复杂选择器需由对照样本继续补齐。
  List<String> _splitOperator(String rule, String operator) {
    return rule.contains(operator) ? rule.split(operator) : <String>[rule];
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

/// CSS 选择器与取值后缀。
final class _CssRule {
  /// 创建 CSS 规则片段。
  const _CssRule({required this.selector, required this.extractor});

  /// CSS 选择器；空字符串表示当前节点。
  final String selector;

  /// `text`、`ownText`、`html`、`all` 或属性名。
  final String extractor;
}
