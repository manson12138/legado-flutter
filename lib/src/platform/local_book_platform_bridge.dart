import 'package:file_picker/file_picker.dart';

import '../domain/model/local_book.dart';

/// 定义本地书系统文件选择器边界，业务层不直接依赖插件类型。
abstract interface class LocalBookPlatformBridge {
  /// 打开系统文档选择器并返回可立即复制的多选文件；取消时返回空列表。
  Future<List<LocalBookPickedFile>> pickBooks();
}

/// 使用 file_picker 连接 Android SAF 与 iOS Document Picker。
final class DefaultLocalBookPlatformBridge implements LocalBookPlatformBridge {
  /// 创建默认本地书平台桥。
  const DefaultLocalBookPlatformBridge();

  /// 选择 Android 基线中的书籍和压缩容器格式，不把内容载入 UI isolate 内存。
  @override
  Future<List<LocalBookPickedFile>> pickBooks() async {
    /// 系统文件选择结果。
    final FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>[
        'txt',
        'epub',
        'umd',
        'mobi',
        'azw',
        'azw3',
        'pdf',
        'zip',
        'rar',
        '7z',
      ],
      allowMultiple: true,
      withData: false,
    );
    if (result == null) {
      return const <LocalBookPickedFile>[];
    }
    /// 插件返回的可复制文件列表。
    final List<LocalBookPickedFile> files = <LocalBookPickedFile>[];
    for (final PlatformFile file in result.files) {
      /// 当前平台临时或外部可读路径。
      final String? filePath = file.path;
      if (filePath != null && filePath.isNotEmpty) {
        files.add(
          LocalBookPickedFile(path: filePath, name: file.name, size: file.size),
        );
      }
    }
    if (files.isEmpty && result.files.isNotEmpty) {
      throw const FormatException('系统没有返回可复制的文件路径，请重新选择');
    }
    return List<LocalBookPickedFile>.unmodifiable(files);
  }
}
