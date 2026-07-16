import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'js_engine.dart';

/// Java/Rhino 白名单调用桥。
///
/// 只实现固定、跨平台且有 Android 调用证据的方法；未知类或方法必须抛出可诊断错误。
final class JavaCompatibilityBridge {
  /// 创建无状态 Java 兼容桥。
  const JavaCompatibilityBridge();

  /// 调用 Legado `java` helper 中可纯 Dart 实现的方法。
  Object? invokeHelper(String method, List<Object?> arguments) {
    return switch (method) {
      'md5Encode' => _md5(_stringArgument(arguments, 0, method)),
      'md5Encode16' => _md5(_stringArgument(arguments, 0, method)).substring(8, 24),
      'base64Encode' => base64Encode(utf8.encode(_stringArgument(arguments, 0, method))),
      'base64Decode' => utf8.decode(
        base64Decode(_stringArgument(arguments, 0, method)),
        allowMalformed: false,
      ),
      'hexDecodeToString' => utf8.decode(
        _hexDecode(_stringArgument(arguments, 0, method)),
        allowMalformed: false,
      ),
      'hexEncode' => _hexEncode(utf8.encode(_stringArgument(arguments, 0, method))),
      'encodeURI' => Uri.encodeFull(_stringArgument(arguments, 0, method)),
      'encodeURIComponent' => Uri.encodeComponent(_stringArgument(arguments, 0, method)),
      'decodeURI' => Uri.decodeFull(_stringArgument(arguments, 0, method)),
      'decodeURIComponent' => Uri.decodeComponent(_stringArgument(arguments, 0, method)),
      'randomUUID' => _randomUuid(),
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持 Legado java.$method',
      ),
    };
  }

  /// 调用 `Java.type` 白名单类的静态方法。
  Object? invokeClass(String className, String method, List<Object?> arguments) {
    if (className == 'org.jsoup.Jsoup' && method == 'parse') {
      return _jsoupDocument(_stringArgument(arguments, 0, '$className.$method'));
    }
    if (className == 'java.net.URLEncoder' && method == 'encode') {
      return Uri.encodeQueryComponent(_stringArgument(arguments, 0, '$className.$method'));
    }
    if (className == 'android.util.Base64') {
      if (method == 'encodeToString') {
        return base64Encode(_byteArguments(arguments, 0, '$className.$method'));
      }
      if (method == 'decode') {
        return base64Decode(_stringArgument(arguments, 0, '$className.$method'));
      }
    }
    throw JsEngineException(
      kind: JsFailureKind.unsupportedApi,
      message: '未支持 Java/Rhino 调用 $className.$method',
    );
  }

  /// 调用固定白名单 HTML 对象方法，跨平台模拟书源常用的只读 Jsoup 链路。
  Object? invokeHost(String type, String method, List<Object?> arguments) {
    if (arguments.isEmpty || arguments.first is! Map) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: '$type.$method 缺少宿主对象',
      );
    }
    /// JavaScript 回传的只读宿主对象快照。
    final Map<Object?, Object?> payload = Map<Object?, Object?>.from(
      arguments.first as Map,
    );
    /// 去除宿主对象本身后的方法参数。
    final List<Object?> methodArguments = arguments.skip(1).toList(growable: false);
    return switch (type) {
      'jsoupDocument' => _invokeJsoupDocument(payload, method, methodArguments),
      'jsoupElements' => _invokeJsoupElements(payload, method, methodArguments),
      'jsoupElement' => _invokeJsoupElement(payload, method, methodArguments),
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持宿主对象 $type.$method',
      ),
    };
  }

  /// 执行 Jsoup Document 常用只读方法。
  Object? _invokeJsoupDocument(
    Map<Object?, Object?> payload,
    String method,
    List<Object?> arguments,
  ) {
    /// 从宿主快照恢复的 HTML Document。
    final Document document = html_parser.parse(payload['html']?.toString() ?? '');
    return switch (method) {
      'select' => _jsoupElements(
        document.querySelectorAll(_stringArgument(arguments, 0, 'Jsoup.Document.select')),
      ),
      'text' => document.body?.text ?? document.documentElement?.text ?? '',
      'html' => document.outerHtml,
      'outerHtml' => document.outerHtml,
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持 Jsoup Document.$method',
      ),
    };
  }

  /// 执行 Jsoup Elements 常用只读方法；修改 DOM 的方法保持明确不支持。
  Object? _invokeJsoupElements(
    Map<Object?, Object?> payload,
    String method,
    List<Object?> arguments,
  ) {
    /// 从宿主快照恢复的 HTML 元素列表。
    final List<Element> elements = _payloadElements(payload);
    return switch (method) {
      'size' => elements.length,
      'get' => _elementAt(
        elements,
        _intArgument(arguments, 0, 'Jsoup.Elements.get'),
      ),
      'first' => elements.isEmpty ? null : _jsoupElement(elements.first),
      'last' => elements.isEmpty ? null : _jsoupElement(elements.last),
      'text' => elements.map((Element element) => element.text).join(' '),
      'html' => elements.map((Element element) => element.innerHtml).join(),
      'outerHtml' => elements.map((Element element) => element.outerHtml).join(),
      'attr' => elements.isEmpty
          ? ''
          : elements.first.attributes[
                  _stringArgument(arguments, 0, 'Jsoup.Elements.attr')
                ] ??
                '',
      'remove' => throw const JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: 'Jsoup Elements.remove 需要可变 DOM 会话，当前只读白名单不支持',
      ),
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持 Jsoup Elements.$method',
      ),
    };
  }

  /// 执行 Jsoup Element 常用只读方法。
  Object? _invokeJsoupElement(
    Map<Object?, Object?> payload,
    String method,
    List<Object?> arguments,
  ) {
    /// 从宿主快照恢复的单个 HTML 元素。
    final Element? element = html_parser.parseFragment(
      payload['html']?.toString() ?? '',
    ).children.firstOrNull;
    if (element == null) {
      return null;
    }
    return switch (method) {
      'select' => _jsoupElements(
        element.querySelectorAll(_stringArgument(arguments, 0, 'Jsoup.Element.select')),
      ),
      'attr' => element.attributes[
              _stringArgument(arguments, 0, 'Jsoup.Element.attr')
            ] ??
            '',
      'text' => element.text,
      'html' => element.innerHtml,
      'outerHtml' => element.outerHtml,
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持 Jsoup Element.$method',
      ),
    };
  }

  /// 把 HTML 文本包装成 JavaScript 可识别的只读 Jsoup Document 快照。
  Map<String, Object?> _jsoupDocument(String html) {
    /// 规范化后的 HTML Document。
    final Document document = html_parser.parse(html);
    return <String, Object?>{
      '_legadoHostType': 'jsoupDocument',
      'html': document.outerHtml,
    };
  }

  /// 把 HTML 元素列表包装成 JavaScript 可识别的只读 Jsoup Elements 快照。
  Map<String, Object?> _jsoupElements(List<Element> elements) {
    return <String, Object?>{
      '_legadoHostType': 'jsoupElements',
      'items': elements.map((Element element) => element.outerHtml).toList(growable: false),
    };
  }

  /// 把单个 HTML 元素包装成 JavaScript 可识别的只读 Jsoup Element 快照。
  Map<String, Object?> _jsoupElement(Element element) {
    return <String, Object?>{
      '_legadoHostType': 'jsoupElement',
      'html': element.outerHtml,
    };
  }

  /// 从 Jsoup Elements 快照中恢复独立的 HTML 元素列表。
  List<Element> _payloadElements(Map<Object?, Object?> payload) {
    /// 宿主快照中的元素 HTML 列表。
    final Object? rawItems = payload['items'];
    if (rawItems is! List) {
      return <Element>[];
    }
    /// 逐项恢复且过滤无根元素片段后的列表。
    final List<Element> elements = <Element>[];
    for (final Object? rawItem in rawItems) {
      /// 当前 HTML 片段中的首个根元素。
      final Element? element = html_parser.parseFragment(
        rawItem?.toString() ?? '',
      ).children.firstOrNull;
      if (element != null) {
        elements.add(element);
      }
    }
    return elements;
  }

  /// 按 Jsoup `Elements.get` 语义读取索引，越界时报告桥参数错误。
  Object? _elementAt(List<Element> elements, int index) {
    if (index < 0 || index >= elements.length) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: 'Jsoup Elements.get 索引越界',
      );
    }
    return _jsoupElement(elements[index]);
  }

  /// 读取必需整数参数。
  int _intArgument(List<Object?> arguments, int index, String method) {
    if (index >= arguments.length) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: '$method 缺少第 ${index + 1} 个参数',
      );
    }
    /// JavaScript 数值或数值字符串转换后的索引。
    final int? value = int.tryParse(arguments[index]?.toString() ?? '');
    if (value == null) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: '$method 的第 ${index + 1} 个参数必须是整数',
      );
    }
    return value;
  }

  /// 计算 UTF-8 文本 MD5。
  String _md5(String value) {
    return md5.convert(utf8.encode(value)).toString();
  }

  /// 读取必需字符串参数。
  String _stringArgument(List<Object?> arguments, int index, String method) {
    if (index >= arguments.length) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: '$method 缺少第 ${index + 1} 个参数',
      );
    }
    return arguments[index]?.toString() ?? '';
  }

  /// 读取字节参数，兼容 Uint8List 与数值列表。
  List<int> _byteArguments(List<Object?> arguments, int index, String method) {
    if (index >= arguments.length) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: '$method 缺少第 ${index + 1} 个参数',
      );
    }
    /// 原始字节参数。
    final Object? value = arguments[index];
    if (value is List) {
      return value.map<int>((Object? item) {
        if (item is num) {
          return item.toInt() & 0xFF;
        }
        throw JsEngineException(
          kind: JsFailureKind.bridge,
          message: '$method 的字节列表包含非数值项',
        );
      }).toList(growable: false);
    }
    throw JsEngineException(
      kind: JsFailureKind.bridge,
      message: '$method 需要字节列表参数',
    );
  }

  /// 解码十六进制文本。
  List<int> _hexDecode(String value) {
    /// 去除空白后的十六进制文本。
    final String normalized = value.replaceAll(RegExp(r'\s+'), '');
    if (normalized.length.isOdd) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: '十六进制文本长度必须为偶数',
      );
    }
    /// 字节结果。
    final List<int> result = <int>[];
    for (int index = 0; index < normalized.length; index += 2) {
      /// 当前字节。
      final int? byte = int.tryParse(normalized.substring(index, index + 2), radix: 16);
      if (byte == null) {
        throw const JsEngineException(
          kind: JsFailureKind.bridge,
          message: '十六进制文本包含无效字符',
        );
      }
      result.add(byte);
    }
    return result;
  }

  /// 编码字节为小写十六进制文本。
  String _hexEncode(List<int> bytes) {
    return bytes.map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 使用安全随机数生成 RFC 4122 v4 UUID。
  String _randomUuid() {
    /// 安全随机源。
    final Random random = Random.secure();
    /// 16 字节 UUID。
    final List<int> bytes = List<int>.generate(16, (int index) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    /// 十六进制 UUID。
    final String value = _hexEncode(bytes);
    return '${value.substring(0, 8)}-'
        '${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-'
        '${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }
}
