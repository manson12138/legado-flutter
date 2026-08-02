import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

/// 本地封面选择与应用私有副本管理边界。
///
/// 对应 Android `BookInfoEditScreen` 的 `SelectImageContract` 与
/// `BookInfoEditViewModel.coverChangeTo`。Android SAF 和 iOS Document Picker 返回的路径
/// 都只在本次选择期间读取，持久化到 `customCoverUrl` 的始终是应用支持目录内的副本。
abstract interface class LocalBookCoverService {
  /// 打开系统图片选择器，把选中图片复制到应用私有目录并返回完整路径；取消时返回空值。
  Future<String?> pickAndPersist(String bookUrl);

  /// 删除由本服务管理的旧封面；网络地址、外部路径和 [exceptPath] 不会被删除。
  Future<void> deleteManagedCover(String? coverPath, {String? exceptPath});
}

/// 使用 `file_picker` 和应用支持目录实现双端本地封面持久化。
final class DefaultLocalBookCoverService implements LocalBookCoverService {
  /// 创建默认本地封面服务。
  const DefaultLocalBookCoverService();

  /// 应用支持目录下稳定的用户封面子目录名。
  static const String _directoryName = 'custom_book_covers';

  /// 选择图片并按书籍与内容摘要生成稳定文件名，避免临时授权路径被长期保存。
  @override
  Future<String?> pickAndPersist(String bookUrl) async {
    /// 系统图片选择结果。
    final FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
    if (result == null) {
      return null;
    }
    if (result.files.isEmpty) {
      throw const FormatException('系统没有返回所选图片');
    }
    /// 插件返回的首个且唯一图片。
    final PlatformFile pickedFile = result.files.first;
    /// 当前平台授予的一次性可读路径。
    final String sourcePath = pickedFile.path?.trim() ?? '';
    if (sourcePath.isEmpty) {
      throw const FormatException('系统没有返回可复制的图片路径，请重新选择');
    }
    /// 等待复制的外部图片。
    final File sourceFile = File(sourcePath);
    if (!await sourceFile.exists() || await sourceFile.length() <= 0) {
      throw const FormatException('所选图片不存在或内容为空');
    }
    /// 用户图片的长期私有目录。
    final Directory directory = await _managedDirectory();
    /// 书籍主键摘要，确保不同书籍即使选择相同图片也拥有独立生命周期。
    final String bookDigest = sha256.convert(utf8.encode(bookUrl)).toString();
    /// 图片内容摘要，重复选择同一图片时复用同一本书的现有副本。
    final Digest contentDigest = await sha256.bind(sourceFile.openRead()).first;
    /// 只保留安全扩展名；解码仍以真实文件内容为准。
    final String extension = _safeExtension(pickedFile, sourcePath);
    /// 正式私有副本路径。
    final String targetPath = path_util.join(
      directory.path,
      '${bookDigest.substring(0, 16)}_${contentDigest.toString()}.$extension',
    );
    /// 已经存在的同内容副本。
    final File targetFile = File(targetPath);
    if (await targetFile.exists() && await targetFile.length() > 0) {
      return targetFile.path;
    }
    /// 同目录临时文件；写完后再改名，避免数据库观察者读到半张图片。
    final File temporaryFile = File(
      '$targetPath.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await sourceFile.copy(temporaryFile.path);
      if (await temporaryFile.length() <= 0) {
        throw const FileSystemException('复制后的图片内容为空');
      }
      try {
        await temporaryFile.rename(targetFile.path);
      } on FileSystemException {
        await temporaryFile.copy(targetFile.path);
        await temporaryFile.delete();
      }
      return targetFile.path;
    } on Object {
      if (await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
      rethrow;
    }
  }

  /// 只允许删除应用支持目录内的受管文件，避免误删外部相册或本地书资源。
  @override
  Future<void> deleteManagedCover(
    String? coverPath, {
    String? exceptPath,
  }) async {
    /// 标准化后的待删除地址。
    final String normalizedValue = coverPath?.trim() ?? '';
    if (normalizedValue.isEmpty || normalizedValue == exceptPath?.trim()) {
      return;
    }
    /// 网络地址和其他非文件 URI 不属于本服务。
    final Uri? uri = Uri.tryParse(normalizedValue);
    if (uri?.scheme == 'http' || uri?.scheme == 'https') {
      return;
    }
    /// `file:` URI 与普通完整路径统一转换为文件系统路径。
    final String candidatePath = uri?.scheme == 'file'
        ? uri?.toFilePath() ?? normalizedValue
        : normalizedValue;
    /// 用户封面的应用私有根目录。
    final Directory directory = await _managedDirectory();
    /// 规范化后再判断包含关系，阻止 `..` 逃逸。
    final String normalizedRoot = path_util.normalize(
      path_util.absolute(directory.path),
    );
    final String normalizedCandidate = path_util.normalize(
      path_util.absolute(candidatePath),
    );
    if (!path_util.isWithin(normalizedRoot, normalizedCandidate)) {
      return;
    }
    /// 仅删除真实存在的受管文件。
    final File file = File(normalizedCandidate);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 返回应用支持目录中的用户封面目录并确保它存在。
  Future<Directory> _managedDirectory() async {
    /// 系统分配的不可再生用户数据目录。
    final Directory supportDirectory = await getApplicationSupportDirectory();
    /// 与可清理网络图片缓存分离的用户封面目录。
    final Directory directory = Directory(
      path_util.join(supportDirectory.path, _directoryName),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// 从插件扩展名或路径中提取只含字母数字的安全后缀。
  String _safeExtension(PlatformFile pickedFile, String sourcePath) {
    /// 插件优先提供的不含点扩展名。
    final String pluginExtension = pickedFile.extension?.trim() ?? '';
    /// 路径中的回退扩展名。
    final String pathExtension = path_util
        .extension(sourcePath)
        .replaceFirst('.', '');
    /// 待清理的扩展名。
    final String rawExtension = pluginExtension.isNotEmpty
        ? pluginExtension
        : pathExtension;
    /// 只保留文件名安全字符并限制长度。
    final String normalized = rawExtension
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]'), '');
    if (normalized.isEmpty || normalized.length > 10) {
      return 'img';
    }
    return normalized;
  }
}
