import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../domain/model/book.dart';
import '../../domain/model/local_book.dart';
import 'local_book_parser.dart';

/// 管理本地书应用私有副本、稳定指纹和数据库相对路径编码。
final class LocalBookStorage {
  /// 创建无状态的本地文件存储服务。
  const LocalBookStorage();

  /// 单本本地书允许的最大文件大小，防止误选异常文件耗尽空间。
  static const int maxBookBytes = 1024 * 1024 * 1024;

  /// 将系统选取文件复制到应用目录并返回稳定引用。
  Future<LocalBookFileReference> persist(LocalBookPickedFile pickedFile) async {
    /// 系统选取结果对应的可读文件。
    final File source = File(pickedFile.path);
    if (!await source.exists()) {
      throw const LocalBookException('选择的文件已不存在或临时读取权限已经失效');
    }
    /// 从真实文件系统读取的文件状态。
    final FileStat stat = await source.stat();
    if (stat.size <= 0) {
      throw const LocalBookException('不能导入空文件');
    }
    if (stat.size > maxBookBytes) {
      throw const LocalBookException('单本书不能超过 1 GiB');
    }
    /// 根据扩展名和必要文件签名识别的格式。
    final LocalBookFormat format = await detectFormat(source, pickedFile.name);
    if (format == LocalBookFormat.zip ||
        format == LocalBookFormat.rar ||
        format == LocalBookFormat.sevenZip) {
      throw LocalBookException('${path.extension(pickedFile.name).toUpperCase()} 压缩包条目选择尚未接入');
    }
    /// 全文件 SHA-256 指纹，既用于稳定身份也用于精确重复导入判断。
    final Digest digest = await sha256.bind(source.openRead()).first;
    /// 小写十六进制内容指纹。
    final String contentHash = digest.toString();
    /// 仅保留安全扩展名的应用内文件名。
    final String relativePath = '$contentHash.${_extensionFor(format)}';
    /// 应用本地书私有根目录。
    final Directory root = await _rootDirectory();
    /// 最终应用内副本。
    final File target = File(path.join(root.path, relativePath));
    if (!await target.exists()) {
      /// 先复制到同目录临时文件，完成后再原子改名，避免中断留下半本书。
      final File temporary = File('${target.path}.importing');
      if (await temporary.exists()) {
        await temporary.delete();
      }
      await source.openRead().pipe(temporary.openWrite());
      await temporary.rename(target.path);
    }
    return LocalBookFileReference(
      relativePath: relativePath,
      displayName: pickedFile.name,
      format: format,
      contentHash: contentHash,
      size: stat.size,
      modifiedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 根据文件引用解析当前安装中真实的应用内路径。
  Future<String> resolve(LocalBookFileReference reference) async {
    /// 应用本地书私有根目录。
    final Directory root = await _rootDirectory();
    return path.join(root.path, reference.relativePath);
  }

  /// 从持久化书籍直接恢复应用内副本绝对路径，供 PDF 页面渲染入口使用。
  Future<String> resolveBook(Book book) async {
    /// 从 Book.variable 解码的稳定文件引用。
    final LocalBookFileReference reference = decodeReference(book);
    return resolve(reference);
  }

  /// 删除尚未写入书架的应用内副本，用于导入失败补偿。
  Future<void> deleteCopy(LocalBookFileReference reference) async {
    /// 当前安装中副本的绝对路径。
    final String filePath = await resolve(reference);
    /// 需要补偿清理的文件。
    final File file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 将本地文件引用编码到 Book.variable，避免新增数据库列和迁移。
  String encodeReference(LocalBookFileReference reference) {
    return jsonEncode(<String, Object>{
      'localBook': <String, Object>{
        'relativePath': reference.relativePath,
        'displayName': reference.displayName,
        'format': reference.format.name,
        'contentHash': reference.contentHash,
        'size': reference.size,
        'modifiedAt': reference.modifiedAt,
      },
    });
  }

  /// 从持久化书籍恢复本地文件引用，损坏数据返回明确错误。
  LocalBookFileReference decodeReference(Book book) {
    /// 数据库保存的本地书引用 JSON。
    final String? source = book.variable;
    if (source == null || source.trim().isEmpty) {
      throw const LocalBookException('本地书缺少应用内文件引用');
    }
    try {
      /// 解码后的 JSON 根对象。
      final Object? decoded = jsonDecode(source);
      if (decoded is! Map<Object?, Object?>) {
        throw const FormatException('根节点不是对象');
      }
      /// localBook 子对象。
      final Object? localValue = decoded['localBook'];
      if (localValue is! Map<Object?, Object?>) {
        throw const FormatException('缺少 localBook');
      }
      /// 持久化格式名称。
      final Object? formatValue = localValue['format'];
      /// 与名称匹配的格式，未知名称不会回退到 TXT。
      final LocalBookFormat? format = formatValue is String
          ? _formatFromName(formatValue)
          : null;
      /// 持久化相对路径。
      final Object? relativePath = localValue['relativePath'];
      /// 持久化显示名。
      final Object? displayName = localValue['displayName'];
      /// 持久化内容指纹。
      final Object? contentHash = localValue['contentHash'];
      /// 持久化文件大小。
      final Object? size = localValue['size'];
      /// 持久化副本时间。
      final Object? modifiedAt = localValue['modifiedAt'];
      if (relativePath is! String ||
          displayName is! String ||
          contentHash is! String ||
          size is! num ||
          modifiedAt is! num ||
          format == null ||
          relativePath.contains('..') ||
          path.isAbsolute(relativePath)) {
        throw const FormatException('字段无效');
      }
      return LocalBookFileReference(
        relativePath: relativePath,
        displayName: displayName,
        format: format,
        contentHash: contentHash,
        size: size.toInt(),
        modifiedAt: modifiedAt.toInt(),
      );
    } on LocalBookException {
      rethrow;
    } catch (error) {
      throw const LocalBookException('本地书文件引用已经损坏，请重新导入该文件');
    }
  }

  /// 使用扩展名和关键签名识别格式，避免把任意文件伪装为电子书。
  Future<LocalBookFormat> detectFormat(File file, String displayName) async {
    /// 归一化的小写扩展名。
    final String extension = path.extension(displayName).toLowerCase();
    /// 文件开头最多十六字节，用于 ZIP、PDF 和 7Z 签名判断。
    final List<int> signature = await file.openRead(0, 16).fold<List<int>>(
      <int>[],
      (List<int> value, List<int> chunk) => <int>[...value, ...chunk],
    );
    /// 是否为 ZIP 的 PK 文件头。
    final bool isZip = signature.length >= 4 &&
        signature[0] == 0x50 &&
        signature[1] == 0x4B &&
        <int>{0x03, 0x05, 0x07}.contains(signature[2]);
    /// 是否为 PDF 的 `%PDF-` 文件头。
    final bool isPdf = signature.length >= 5 &&
        signature[0] == 0x25 &&
        signature[1] == 0x50 &&
        signature[2] == 0x44 &&
        signature[3] == 0x46 &&
        signature[4] == 0x2D;
    if (extension == '.epub' && isZip) {
      return LocalBookFormat.epub;
    }
    if (extension == '.zip' && isZip) {
      return LocalBookFormat.zip;
    }
    if (extension == '.pdf' && isPdf) {
      return LocalBookFormat.pdf;
    }
    return switch (extension) {
      '.txt' => LocalBookFormat.txt,
      '.umd' => LocalBookFormat.umd,
      '.mobi' => LocalBookFormat.mobi,
      '.azw' => LocalBookFormat.azw,
      '.azw3' => LocalBookFormat.azw3,
      '.rar' => LocalBookFormat.rar,
      '.7z' => LocalBookFormat.sevenZip,
      '.epub' => throw const LocalBookException('EPUB 文件缺少有效 ZIP 容器签名'),
      '.pdf' => throw const LocalBookException('PDF 文件缺少有效 PDF 签名'),
      _ => throw const LocalBookException('当前文件格式不在 Android 本地书兼容范围内'),
    };
  }

  /// 返回应用私有本地书目录并确保目录存在。
  Future<Directory> _rootDirectory() async {
    /// 当前平台为数据库分配的应用私有目录。
    final String databasesPath = await getDatabasesPath();
    /// 与数据库同级的本地书目录。
    final Directory directory = Directory(path.join(path.dirname(databasesPath), 'local_books'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// 返回格式对应的标准安全扩展名。
  String _extensionFor(LocalBookFormat format) {
    return switch (format) {
      LocalBookFormat.sevenZip => '7z',
      _ => format.name,
    };
  }

  /// 将持久化枚举名称安全恢复为格式，未知名称返回 null。
  LocalBookFormat? _formatFromName(String name) {
    for (final LocalBookFormat format in LocalBookFormat.values) {
      if (format.name == name) {
        return format;
      }
    }
    return null;
  }
}
