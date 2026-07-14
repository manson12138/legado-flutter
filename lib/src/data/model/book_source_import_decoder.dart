import 'dart:convert';

import '../../domain/model/book_source.dart';
import '../../domain/model/book_source_import_result.dart';

/// 外部书源 JSON 完成逐条类型收窄后的数据批次。
final class DecodedBookSourceBatch {
  /// 创建包含有效书源和无效项摘要的不可变批次。
  DecodedBookSourceBatch({
    required this.total,
    required List<BookSource> sources,
    required List<BookSourceImportIssue> issues,
  }) : sources = List<BookSource>.unmodifiable(sources),
       issues = List<BookSourceImportIssue>.unmodifiable(issues);

  /// 外部根数组的条目总数。
  final int total;

  /// 已通过字段校验的书源。
  final List<BookSource> sources;

  /// 未通过字段校验的安全摘要。
  final List<BookSourceImportIssue> issues;
}

/// 将外部书源 JSON 转换为受控 [BookSource]，隔离不可信动态输入与数据库对象。
final class BookSourceImportDecoder {
  /// 创建无状态书源导入解码器。
  const BookSourceImportDecoder();

  /// 解码 Android 兼容的单个对象或对象数组；任一对象非法时整体失败。
  List<BookSource> decode(String sourceJson) {
    /// 带逐条错误信息的解码批次。
    final DecodedBookSourceBatch batch = decodeBatch(sourceJson);
    if (batch.issues.isNotEmpty) {
      throw FormatException(batch.issues.first.message);
    }
    return batch.sources;
  }

  /// 解码对象、数组或包裹 JSON 的转义字符串，并保留单条失败结果。
  DecodedBookSourceBatch decodeBatch(String sourceJson) {
    /// 外部 JSON 的根值，必须在进入数据库前完成类型收窄。
    Object? decodedRoot = jsonDecode(sourceJson);
    if (decodedRoot is String) {
      decodedRoot = jsonDecode(decodedRoot);
    }
    /// 统一后的书源对象根值列表。
    final List<Object?> sourceValues = decodedRoot is List<Object?>
        ? decodedRoot
        : <Object?>[decodedRoot];
    if (sourceValues.isEmpty) {
      throw const FormatException('书源数组不能为空');
    }
    /// 完成字段校验和默认值处理的书源列表。
    final List<BookSource> sources = <BookSource>[];
    /// 未通过字段校验的条目摘要。
    final List<BookSourceImportIssue> issues = <BookSourceImportIssue>[];

    for (int index = 0; index < sourceValues.length; index += 1) {
      try {
        /// 当前待解析书源的外部根值。
        final Object? sourceValue = sourceValues[index];
        /// 当前书源只包含字符串键的字段映射。
        final Map<String, Object?> json = _asObjectMap(
          sourceValue,
          location: '书源[$index]',
        );
        sources.add(_decodeSource(json, index));
      } on FormatException catch (error) {
        issues.add(
          BookSourceImportIssue(index: index, message: error.message.toString()),
        );
      }
    }
    return DecodedBookSourceBatch(
      total: sourceValues.length,
      sources: sources,
      issues: issues,
    );
  }

  /// 将一个已收窄 JSON 对象转换为持久化书源。
  BookSource _decodeSource(Map<String, Object?> json, int index) {
    /// 用于错误消息定位当前对象的字段前缀。
    final String location = '书源[$index]';
    return BookSource(
      bookSourceUrl: _requiredString(json, 'bookSourceUrl', location),
      bookSourceName: _requiredString(json, 'bookSourceName', location),
      bookSourceGroup: _nullableString(json, 'bookSourceGroup', location),
      bookSourceType: _intValue(json, 'bookSourceType', 0, location),
      bookUrlPattern: _nullableString(json, 'bookUrlPattern', location),
      customOrder: _intValue(json, 'customOrder', 0, location),
      enabled: _boolValue(json, 'enabled', true, location),
      enabledExplore: _boolValue(json, 'enabledExplore', true, location),
      jsLib: _nullableString(json, 'jsLib', location),
      enabledCookieJar: _nullableBoolValue(
        json,
        'enabledCookieJar',
        true,
        location,
      ),
      concurrentRate: _nullableString(json, 'concurrentRate', location),
      header: _jsonCompatibleText(json, 'header', location),
      loginUrl: _nullableString(json, 'loginUrl', location),
      loginUi: _jsonCompatibleText(json, 'loginUi', location),
      loginCheckJs: _nullableString(json, 'loginCheckJs', location),
      coverDecodeJs: _nullableString(json, 'coverDecodeJs', location),
      bookSourceComment: _nullableString(json, 'bookSourceComment', location),
      variableComment: _nullableString(json, 'variableComment', location),
      lastUpdateTime: _intValue(json, 'lastUpdateTime', 0, location),
      respondTime: _intValue(json, 'respondTime', 180000, location),
      weight: _intValue(json, 'weight', 0, location),
      exploreUrl: _nullableString(json, 'exploreUrl', location),
      exploreScreen: _jsonCompatibleText(json, 'exploreScreen', location),
      ruleExplore: _jsonCompatibleText(json, 'ruleExplore', location),
      searchUrl: _nullableString(json, 'searchUrl', location),
      ruleSearch: _jsonCompatibleText(json, 'ruleSearch', location),
      ruleBookInfo: _jsonCompatibleText(json, 'ruleBookInfo', location),
      ruleToc: _jsonCompatibleText(json, 'ruleToc', location),
      ruleContent: _jsonCompatibleText(json, 'ruleContent', location),
      ruleReview: _jsonCompatibleText(json, 'ruleReview', location),
      eventListener: _boolValue(json, 'eventListener', false, location),
      customButton: _boolValue(json, 'customButton', false, location),
      homepageModules: _jsonCompatibleText(json, 'homepageModules', location),
      extraFieldsJson: _unknownFieldsJson(json),
    );
  }

  /// 将当前模型尚未识别的字段编码保存，避免编辑和重新持久化时静默丢失。
  String? _unknownFieldsJson(Map<String, Object?> json) {
    /// 当前模型已经明确处理的字段名。
    const Set<String> knownFields = <String>{
      'bookSourceUrl',
      'bookSourceName',
      'bookSourceGroup',
      'bookSourceType',
      'bookUrlPattern',
      'customOrder',
      'enabled',
      'enabledExplore',
      'jsLib',
      'enabledCookieJar',
      'concurrentRate',
      'header',
      'loginUrl',
      'loginUi',
      'loginCheckJs',
      'coverDecodeJs',
      'bookSourceComment',
      'variableComment',
      'lastUpdateTime',
      'respondTime',
      'weight',
      'exploreUrl',
      'exploreScreen',
      'ruleExplore',
      'searchUrl',
      'ruleSearch',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
      'ruleReview',
      'eventListener',
      'customButton',
      'homepageModules',
      'extraFieldsJson',
    };
    /// 未知字段及其原始 JSON 值。
    final Map<String, Object?> unknownFields = <String, Object?>{};
    /// Flutter 导出文件可能携带的既有未知字段 JSON。
    final Object? storedUnknownFields = json['extraFieldsJson'];
    if (storedUnknownFields is String && storedUnknownFields.trim().isNotEmpty) {
      /// 已保存未知字段的外部解码值。
      final Object? decodedStoredFields = jsonDecode(storedUnknownFields);
      if (decodedStoredFields is! Map<Object?, Object?>) {
        throw const FormatException('extraFieldsJson 必须编码 JSON 对象');
      }
      for (final MapEntry<Object?, Object?> entry in decodedStoredFields.entries) {
        if (entry.key is! String) {
          throw const FormatException('extraFieldsJson 包含非字符串字段名');
        }
        unknownFields[entry.key.toString()] = entry.value;
      }
    }
    for (final MapEntry<String, Object?> entry in json.entries) {
      if (!knownFields.contains(entry.key)) {
        unknownFields[entry.key] = entry.value;
      }
    }
    return unknownFields.isEmpty ? null : jsonEncode(unknownFields);
  }

  /// 将外部 Map 收窄为仅字符串键的字段映射。
  Map<String, Object?> _asObjectMap(Object? value, {required String location}) {
    if (value is! Map<Object?, Object?>) {
      throw FormatException('$location 必须是 JSON 对象');
    }
    /// 完成字符串键检查后的对象字段。
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      /// 当前外部字段键。
      final Object? key = entry.key;
      if (key is! String) {
        throw FormatException('$location 包含非字符串字段名');
      }
      result[key] = entry.value;
    }
    return result;
  }

  /// 读取不可缺失且不可为空的字符串字段。
  String _requiredString(
    Map<String, Object?> json,
    String field,
    String location,
  ) {
    /// 当前字段的外部值。
    final Object? value = json[field];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw FormatException('$location.$field 必须是非空字符串');
  }

  /// 读取可空字符串字段，并保留 `null` 与空字符串的区别。
  String? _nullableString(
    Map<String, Object?> json,
    String field,
    String location,
  ) {
    if (!json.containsKey(field)) {
      return null;
    }
    /// 当前字段的外部值。
    final Object? value = json[field];
    if (value == null || value is String) {
      return value as String?;
    }
    throw FormatException('$location.$field 必须是字符串或 null');
  }

  /// 读取兼容历史书源的整数值；允许 JSON 数字和十进制数字字符串。
  int _intValue(
    Map<String, Object?> json,
    String field,
    int defaultValue,
    String location,
  ) {
    if (!json.containsKey(field) || json[field] == null) {
      return defaultValue;
    }
    /// 当前字段的外部值。
    final Object? value = json[field];
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      /// 历史 JSON 数字字符串的解析结果。
      final int? parsed = int.tryParse(value);
      if (parsed != null) {
        return parsed;
      }
    }
    throw FormatException('$location.$field 必须是整数');
  }

  /// 读取兼容历史书源的不可空布尔值；允许 true/false、1/0 及其字符串形式。
  bool _boolValue(
    Map<String, Object?> json,
    String field,
    bool defaultValue,
    String location,
  ) {
    /// 保留字段缺失时应使用的业务默认值。
    final bool? value = _nullableBoolValue(
      json,
      field,
      defaultValue,
      location,
    );
    return value ?? defaultValue;
  }

  /// 读取兼容历史书源的可空布尔值，不用 false 代替显式 null。
  bool? _nullableBoolValue(
    Map<String, Object?> json,
    String field,
    bool? defaultValue,
    String location,
  ) {
    if (!json.containsKey(field)) {
      return defaultValue;
    }
    /// 当前字段的外部值。
    final Object? value = json[field];
    if (value == null || value is bool) {
      return value as bool?;
    }
    if (value == 1 || value == '1' || value == 'true') {
      return true;
    }
    if (value == 0 || value == '0' || value == 'false') {
      return false;
    }
    throw FormatException('$location.$field 必须是布尔值、1、0 或 null');
  }

  /// 将规则字段的字符串原样保留，将对象或数组稳定编码为 JSON 文本。
  String? _jsonCompatibleText(
    Map<String, Object?> json,
    String field,
    String location,
  ) {
    if (!json.containsKey(field)) {
      return null;
    }
    /// 当前规则或配置字段的外部值。
    final Object? value = json[field];
    if (value == null || value is String) {
      return value as String?;
    }
    if (value is Map<Object?, Object?> || value is List<Object?>) {
      return jsonEncode(value);
    }
    throw FormatException('$location.$field 必须是字符串、对象、数组或 null');
  }
}
