import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// 书源管理使用的系统文件选择边界。
abstract interface class BookSourcePlatformBridge {
  /// 打开系统文件选择器并返回 UTF-8 JSON/TXT 文本；取消时返回 null。
  Future<String?> pickSourceText();
}

/// 使用系统文档选择器读取小型书源文件的平台实现。
///
/// iOS Document Picker 的安全作用域由 file_picker 原生边界管理；本实现只接收内存字节，
/// 解码完成后不保存外部 URL 或临时绝对路径，因此长期访问不依赖外部授权。
final class DefaultBookSourcePlatformBridge implements BookSourcePlatformBridge {
  /// 创建默认平台桥。
  const DefaultBookSourcePlatformBridge();

  /// 单次导入允许读取的最大字节数，避免书源文件造成内存压力。
  static const int maxImportBytes = 5 * 1024 * 1024;

  /// 使用系统文档选择器读取 JSON、TXT 或 HTML 后缀的 UTF-8 文件。
  @override
  Future<String?> pickSourceText() async {
    /// 系统文件选择结果。
    final FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['json', 'txt', 'html'],
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return null;
    }
    /// 用户选中的单个文件。
    final PlatformFile file = result.files.first;
    if (file.size > maxImportBytes) {
      throw const FormatException('书源文件不能超过 5 MiB');
    }
    /// 文件选择器直接载入的字节。
    final Uint8List? bytes = file.bytes;
    if (bytes == null) {
      throw const FormatException('系统未返回可读取的文件内容');
    }
    return utf8.decode(bytes, allowMalformed: false);
  }
}
