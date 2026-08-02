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
/// 都只在本次选择期间读取，持久化到 `customCoverUrl` 的始终是应用支持目录内的稳定标识。
abstract interface class LocalBookCoverService {
  /// 预建应用私有封面目录，使书架首帧可以同步解析稳定封面标识。
  Future<void> warmUp();

  /// 打开系统图片选择器，把选中图片复制到应用私有目录并返回稳定标识；取消时返回空值。
  Future<String?> pickAndPersist(String bookUrl);

  /// 删除由本服务管理的旧封面；网络地址、外部路径和 [exceptPath] 不会被删除。
  Future<void> deleteManagedCover(String? coverPath, {String? exceptPath});
}

/// 在数据库稳定标识与本次运行真实沙盒路径之间转换。
///
/// iOS 的 Application Support 绝对路径前缀可能随容器变化，因此数据库只保存
/// `legado-cover://local/<文件名>`。旧版本已经保存的
/// `.../custom_book_covers/<文件名>` 绝对路径会按文件名自动兼容，不要求重新选择封面。
final class LocalBookCoverReference {
  LocalBookCoverReference._();

  /// 稳定本地封面标识使用的 URI scheme。
  static const String scheme = 'legado-cover';

  /// 稳定本地封面标识使用的 URI host。
  static const String _host = 'local';

  /// 应用支持目录下稳定的用户封面子目录名。
  static const String directoryName = 'custom_book_covers';

  /// 当前进程已经解析出的用户封面目录路径。
  static String? _directoryPath;

  /// 当前进程唯一的目录预建任务。
  static Future<void>? _warmUpTask;

  /// 预建沙盒目录并缓存当前运行的真实路径；失败后允许后续操作重试。
  static Future<void> warmUp() {
    /// 已经存在的预建任务。
    final Future<void>? existingTask = _warmUpTask;
    if (existingTask != null) {
      return existingTask;
    }
    /// 本次目录预建任务。
    final Future<void> task = _performWarmUp();
    _warmUpTask = task;
    return task;
  }

  /// 解析并创建 Application Support 下的不可再生用户封面目录。
  static Future<void> _performWarmUp() async {
    try {
      /// 系统分配的不可再生用户数据目录。
      final Directory supportDirectory = await getApplicationSupportDirectory();
      /// 与可清理网络图片缓存分离的用户封面目录。
      final Directory directory = Directory(
        path_util.join(supportDirectory.path, directoryName),
      );
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      _directoryPath = directory.path;
    } on Object {
      _warmUpTask = null;
      rethrow;
    }
  }

  /// 为沙盒文件名生成不包含易变容器绝对路径的数据库稳定标识。
  static String create(String fileName) {
    /// 去除任何路径成分后的安全文件名。
    final String safeFileName = path_util.basename(fileName.trim());
    if (safeFileName.isEmpty || safeFileName != fileName.trim()) {
      throw const FormatException('本地封面文件名无效');
    }
    return Uri(
      scheme: scheme,
      host: _host,
      pathSegments: <String>[safeFileName],
    ).toString();
  }

  /// 判断数据库值是否为稳定标识或旧版受管绝对路径。
  static bool isManaged(String value) => _managedFileName(value) != null;

  /// 把稳定标识或旧绝对路径统一转换成稳定数据库值；普通地址保持不变。
  static String normalize(String value) {
    /// 清理后的原始地址。
    final String normalizedValue = value.trim();
    /// 受管文件名。
    final String? fileName = _managedFileName(normalizedValue);
    return fileName == null ? normalizedValue : create(fileName);
  }

  /// 同步解析显示路径；目录尚未预热时，稳定标识返回空值等待异步解析。
  static String? resolveSync(String value) {
    /// 清理后的原始地址。
    final String normalizedValue = value.trim();
    /// 受管文件名。
    final String? fileName = _managedFileName(normalizedValue);
    if (fileName == null) {
      return normalizedValue;
    }
    /// 已经缓存的当前沙盒目录。
    final String? directoryPath = _directoryPath;
    if (directoryPath != null) {
      return path_util.join(directoryPath, fileName);
    }
    /// Android 的旧绝对路径通常跨重启稳定；目录未预热时直接使用可避免首帧闪烁。
    if (!normalizedValue.startsWith('$scheme:') &&
        File(normalizedValue).existsSync()) {
      return normalizedValue;
    }
    return null;
  }

  /// 确保目录就绪后解析当前运行真实路径；普通网络地址或外部路径原样返回。
  static Future<String?> resolve(String value) async {
    /// 同步快路径结果。
    final String? resolved = resolveSync(value);
    if (resolved != null) {
      return resolved;
    }
    if (!isManaged(value)) {
      return value.trim();
    }
    await warmUp();
    return resolveSync(value);
  }

  /// 返回当前用户封面目录，供选择复制和受控删除共用。
  static Future<Directory> directory() async {
    await warmUp();
    /// 预热成功后的目录路径。
    final String? directoryPath = _directoryPath;
    if (directoryPath == null) {
      throw const FileSystemException('无法解析本地封面目录');
    }
    return Directory(directoryPath);
  }

  /// 从稳定标识或旧受管路径中提取安全文件名；其他地址返回空值。
  static String? _managedFileName(String value) {
    /// 清理后的候选值。
    final String normalizedValue = value.trim();
    if (normalizedValue.isEmpty) {
      return null;
    }
    /// 尝试按稳定 URI 解析。
    final Uri? uri = Uri.tryParse(normalizedValue);
    if (uri?.scheme == scheme && uri?.host == _host) {
      /// 稳定 URI 中唯一允许的路径段。
      final List<String> segments = uri?.pathSegments ?? const <String>[];
      if (segments.length != 1) {
        return null;
      }
      /// URI 解码后的候选文件名。
      final String fileName = segments.first;
      return fileName.isNotEmpty && path_util.basename(fileName) == fileName
          ? fileName
          : null;
    }
    if (uri != null && uri.hasScheme && uri.scheme != 'file') {
      return null;
    }
    /// 旧值可能是普通绝对路径，也可能是 file URI。
    final String legacyPath = uri?.scheme == 'file'
        ? uri?.toFilePath() ?? normalizedValue
        : normalizedValue;
    /// 旧版数据库保存的沙盒绝对路径标记。
    final String marker =
        '${path_util.separator}$directoryName${path_util.separator}';
    if (!legacyPath.contains(marker)) {
      return null;
    }
    /// 旧路径最后一段文件名。
    final String fileName = path_util.basename(legacyPath);
    return fileName.isEmpty ? null : fileName;
  }
}

/// 使用 `file_picker` 和应用支持目录实现双端本地封面持久化。
final class DefaultLocalBookCoverService implements LocalBookCoverService {
  /// 创建默认本地封面服务。
  const DefaultLocalBookCoverService();

  /// 预建用户封面目录，供公共封面组件同步解析首帧路径。
  @override
  Future<void> warmUp() => LocalBookCoverReference.warmUp();

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
    final Directory directory = await LocalBookCoverReference.directory();
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
      return LocalBookCoverReference.create(path_util.basename(targetFile.path));
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
      return LocalBookCoverReference.create(path_util.basename(targetFile.path));
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
    /// 标准化后的保留地址。
    final String normalizedExcept = LocalBookCoverReference.normalize(
      exceptPath?.trim() ?? '',
    );
    if (normalizedValue.isEmpty ||
        LocalBookCoverReference.normalize(normalizedValue) == normalizedExcept ||
        !LocalBookCoverReference.isManaged(normalizedValue)) {
      return;
    }
    /// 当前运行中受管封面的真实路径。
    final String? candidatePath = await LocalBookCoverReference.resolve(
      normalizedValue,
    );
    if (candidatePath == null) {
      return;
    }
    /// 用户封面的应用私有根目录。
    final Directory directory = await LocalBookCoverReference.directory();
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
