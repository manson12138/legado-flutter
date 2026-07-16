import 'package:file_picker/file_picker.dart';

import '../domain/model/local_book.dart';

/// 定义本地书系统文件选择器边界，业务层不直接依赖插件类型。
abstract interface class LocalBookPlatformBridge {
  /// 打开系统文档选择器并返回可立即复制的多选文件；取消时返回空列表。
  Future<List<LocalBookPickedFile>> pickBooks();
}

/// 使用 file_picker 连接 Android SAF 与 iOS Document Picker。
///
/// iOS 的安全作用域 URL 生命周期由 file_picker 原生实现负责，Dart 边界只接收当前可读路径；
/// 调用方必须立即交给 `LocalBookStorage.persist` 复制，禁止把该外部路径当作长期身份。
final class DefaultLocalBookPlatformBridge implements LocalBookPlatformBridge {
  /// 创建默认本地书平台桥。
  const DefaultLocalBookPlatformBridge();

  /// 选择 Android 基线中的书籍和压缩容器格式，不把内容载入 UI isolate 内存。
  ///
  /// Android 返回 SAF 可读路径，iOS 返回 Document Picker 当前可读路径；两端都只允许在
  /// 本次导入任务中读取，长期访问始终依赖应用私有副本，不依赖插件是否保留外部授权。
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
