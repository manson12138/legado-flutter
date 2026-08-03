import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path_util;

import '../../domain/gateway/manga_image_gateway.dart';
import '../../help/media/app_media_directories.dart';

/// 漫画缓存中已通过文件头和尺寸复检的图片事实。
final class MangaCachedImage {
  /// 创建缓存内部使用的不可变图片描述。
  const MangaCachedImage({
    required this.file,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.byteLength,
  });

  /// 应用私有缓存文件。
  final File file;

  /// 文件头确认的 MIME。
  final String mimeType;

  /// 图片像素宽度。
  final int width;

  /// 图片像素高度。
  final int height;

  /// 图片文件字节数。
  final int byteLength;
}

/// 负责漫画图片缓存身份、复检、损坏清理和同目录原子替换。
final class MangaImageCache {
  /// 创建使用统一媒体目录的漫画缓存。
  const MangaImageCache();

  /// 单张图片允许的最大下载体积，防止异常响应占满内存或缓存。
  static const int maximumByteLength = 40 * 1024 * 1024;

  /// 单边允许的最大像素尺寸。
  static const int _maximumDimension = 32768;

  /// 单张图片允许的最大总像素数。
  static const int _maximumPixelCount = 100 * 1000 * 1000;

  /// 缓存命中复检最多读取的文件头字节数，兼容带较大 JPEG 元数据的资源。
  static const int _maximumInspectionByteLength = 512 * 1024;

  /// 使用用户、书籍、章节和图片请求规则生成不暴露原始地址的稳定缓存键。
  String cacheKey({
    required int userId,
    required String bookUrl,
    required String chapterUrl,
    required String requestUrl,
  }) {
    /// 带版本的缓存身份原文，只在内存中参与摘要计算。
    final String identity = 'manga-image-v1\u001F$userId\u001F$bookUrl\u001F'
        '$chapterUrl\u001F$requestUrl';
    return sha256.convert(utf8.encode(identity)).toString();
  }

  /// 查找并复检已有缓存；损坏或不完整文件会被删除后按未命中处理。
  Future<MangaCachedImage?> lookup(String cacheKey) async {
    /// 漫画正式缓存目录。
    final String directoryPath = await _comicDirectoryPath();
    /// 不依赖远端扩展名的稳定缓存文件。
    final File file = File(path_util.join(directoryPath, '$cacheKey.image'));
    if (!await file.exists()) {
      return null;
    }
    try {
      /// 已缓存文件大小。
      final int byteLength = await file.length();
      if (byteLength <= 0 || byteLength > maximumByteLength) {
        await file.delete();
        return null;
      }
      /// 只读取识别格式和尺寸所需的有界文件头。
      final RandomAccessFile reader = await file.open();
      /// 从缓存文件读取的有界头部字节。
      Uint8List headerBytes;
      try {
        /// 本次复检实际读取的字节数。
        final int readLength = byteLength < _maximumInspectionByteLength
            ? byteLength
            : _maximumInspectionByteLength;
        headerBytes = await reader.read(readLength);
      } finally {
        await reader.close();
      }
      /// 文件头解析结果。
      final _MangaImageInspection? inspection = _inspect(headerBytes);
      if (inspection == null || !_withinDimensionLimit(inspection)) {
        await file.delete();
        return null;
      }
      return MangaCachedImage(
        file: file,
        mimeType: inspection.mimeType,
        width: inspection.width,
        height: inspection.height,
        byteLength: byteLength,
      );
    } on FileSystemException {
      return null;
    }
  }

  /// 校验下载字节的 MIME、文件头和尺寸，再写临时文件并原子替换正式缓存。
  Future<MangaCachedImage> store({
    required String cacheKey,
    required Uint8List bytes,
    required String? declaredContentType,
  }) async {
    if (bytes.isEmpty) {
      throw const MangaImageException(
        MangaImageFailureKind.emptyResponse,
        '图片响应为空',
      );
    }
    if (bytes.length > maximumByteLength) {
      throw const MangaImageException(
        MangaImageFailureKind.tooLarge,
        '图片文件超过大小限制',
      );
    }
    /// 由响应 Header 清理得到的媒体类型。
    final String declaredMimeType =
        (declaredContentType ?? '').split(';').first.trim().toLowerCase();
    if (declaredMimeType.isNotEmpty &&
        declaredMimeType != 'application/octet-stream' &&
        !<String>{'image/jpeg', 'image/jpg', 'image/png', 'image/gif', 'image/webp'}
            .contains(declaredMimeType)) {
      throw const MangaImageException(
        MangaImageFailureKind.unsupportedFormat,
        '响应类型不是支持的图片格式',
      );
    }
    /// 根据真实文件头识别的图片格式和尺寸。
    final _MangaImageInspection? inspection = _inspect(bytes);
    if (inspection == null) {
      throw const MangaImageException(
        MangaImageFailureKind.unsupportedFormat,
        '图片文件头无效或格式不受支持',
      );
    }
    /// 将兼容别名收敛为文件头使用的标准 MIME。
    final String normalizedDeclaredMimeType = declaredMimeType == 'image/jpg'
        ? 'image/jpeg'
        : declaredMimeType;
    if (normalizedDeclaredMimeType.startsWith('image/') &&
        normalizedDeclaredMimeType != inspection.mimeType) {
      throw const MangaImageException(
        MangaImageFailureKind.unsupportedFormat,
        '图片响应类型与文件内容不一致',
      );
    }
    if (!_withinDimensionLimit(inspection)) {
      throw const MangaImageException(
        MangaImageFailureKind.tooLarge,
        '图片像素尺寸超过安全限制',
      );
    }
    /// 漫画正式缓存目录；临时文件放在同一目录保证 rename 不跨文件系统。
    final String directoryPath = await _comicDirectoryPath();
    /// 最终稳定缓存文件。
    final File finalFile = File(path_util.join(directoryPath, '$cacheKey.image'));
    /// 当前写入独占的临时文件。
    final File temporaryFile = File(
      path_util.join(
        directoryPath,
        '.$cacheKey.${DateTime.now().microsecondsSinceEpoch}.downloading',
      ),
    );
    try {
      await temporaryFile.writeAsBytes(bytes, flush: true);
      // Android 与 iOS 的缓存目录都位于 POSIX 文件系统；同目录 rename 直接原子替换，
      // 不先删除旧文件，避免替换窗口内暴露“无正式缓存”的中间状态。
      await temporaryFile.rename(finalFile.path);
      return MangaCachedImage(
        file: finalFile,
        mimeType: inspection.mimeType,
        width: inspection.width,
        height: inspection.height,
        byteLength: bytes.length,
      );
    } on Object {
      try {
        if (await temporaryFile.exists()) {
          await temporaryFile.delete();
        }
      } on Object {
        // 临时目录清理由系统缓存生命周期兜底，不覆盖原始写入失败。
      }
      throw const MangaImageException(
        MangaImageFailureKind.cacheIo,
        '漫画图片缓存写入失败',
      );
    }
  }

  /// 删除指定缓存；文件不存在时视为已经完成失效。
  Future<void> invalidate(String cacheKey) async {
    /// 漫画正式缓存目录。
    final String directoryPath = await _comicDirectoryPath();
    /// 待失效缓存文件。
    final File file = File(path_util.join(directoryPath, '$cacheKey.image'));
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on Object {
      throw const MangaImageException(
        MangaImageFailureKind.cacheIo,
        '漫画图片缓存删除失败',
      );
    }
  }

  /// 解析漫画缓存目录，并把平台目录失败转换为受控缓存错误。
  static Future<String> _comicDirectoryPath() async {
    try {
      return await AppMediaDirectories.instance.directoryPathFor(MediaCategory.comic);
    } on Object {
      throw const MangaImageException(
        MangaImageFailureKind.cacheIo,
        '漫画图片缓存目录不可用',
      );
    }
  }

  /// 识别 PNG、JPEG、GIF 和 WebP 的真实文件头与像素尺寸。
  static _MangaImageInspection? _inspect(Uint8List bytes) {
    return _inspectPng(bytes) ??
        _inspectJpeg(bytes) ??
        _inspectGif(bytes) ??
        _inspectWebp(bytes);
  }

  /// 识别 PNG IHDR 中的大端宽高。
  static _MangaImageInspection? _inspectPng(Uint8List bytes) {
    /// PNG 固定八字节签名。
    const List<int> signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 24 || !_matches(bytes, 0, signature)) {
      return null;
    }
    return _MangaImageInspection(
      mimeType: 'image/png',
      width: _readUint32BigEndian(bytes, 16),
      height: _readUint32BigEndian(bytes, 20),
    );
  }

  /// 扫描 JPEG SOF 标记并读取大端宽高。
  static _MangaImageInspection? _inspectJpeg(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
      return null;
    }
    /// 当前 JPEG 段扫描位置，跳过起始 SOI 标记。
    int offset = 2;
    while (offset + 3 < bytes.length) {
      if (bytes[offset] != 0xff) {
        offset += 1;
        continue;
      }
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset += 1;
      }
      if (offset >= bytes.length) {
        return null;
      }
      /// 当前 JPEG 段标记。
      final int marker = bytes[offset];
      offset += 1;
      if (marker == 0xd8 || marker == 0xd9 || (marker >= 0xd0 && marker <= 0xd7)) {
        continue;
      }
      if (offset + 1 >= bytes.length) {
        return null;
      }
      /// 包含自身两个长度字节的 JPEG 段长度。
      final int segmentLength = _readUint16BigEndian(bytes, offset);
      if (segmentLength < 2 || offset + segmentLength > bytes.length) {
        return null;
      }
      if (_isJpegStartOfFrame(marker) && segmentLength >= 7) {
        return _MangaImageInspection(
          mimeType: 'image/jpeg',
          width: _readUint16BigEndian(bytes, offset + 5),
          height: _readUint16BigEndian(bytes, offset + 3),
        );
      }
      offset += segmentLength;
    }
    return null;
  }

  /// 识别 GIF87a/GIF89a 逻辑屏幕宽高。
  static _MangaImageInspection? _inspectGif(Uint8List bytes) {
    if (bytes.length < 10 ||
        !(_matchesAscii(bytes, 0, 'GIF87a') || _matchesAscii(bytes, 0, 'GIF89a'))) {
      return null;
    }
    return _MangaImageInspection(
      mimeType: 'image/gif',
      width: _readUint16LittleEndian(bytes, 6),
      height: _readUint16LittleEndian(bytes, 8),
    );
  }

  /// 识别 WebP VP8X、VP8L 和 VP8 三种常见容器宽高。
  static _MangaImageInspection? _inspectWebp(Uint8List bytes) {
    if (bytes.length < 30 ||
        !_matchesAscii(bytes, 0, 'RIFF') ||
        !_matchesAscii(bytes, 8, 'WEBP')) {
      return null;
    }
    if (_matchesAscii(bytes, 12, 'VP8X')) {
      return _MangaImageInspection(
        mimeType: 'image/webp',
        width: 1 + _readUint24LittleEndian(bytes, 24),
        height: 1 + _readUint24LittleEndian(bytes, 27),
      );
    }
    if (_matchesAscii(bytes, 12, 'VP8L') && bytes.length >= 25 && bytes[20] == 0x2f) {
      /// VP8L 尺寸位域首字节。
      final int first = bytes[21];
      /// VP8L 尺寸位域第二字节。
      final int second = bytes[22];
      /// VP8L 尺寸位域第三字节。
      final int third = bytes[23];
      /// VP8L 尺寸位域第四字节。
      final int fourth = bytes[24];
      return _MangaImageInspection(
        mimeType: 'image/webp',
        width: 1 + first + ((second & 0x3f) << 8),
        height: 1 + (second >> 6) + (third << 2) + ((fourth & 0x0f) << 10),
      );
    }
    if (_matchesAscii(bytes, 12, 'VP8 ') &&
        bytes[23] == 0x9d &&
        bytes[24] == 0x01 &&
        bytes[25] == 0x2a) {
      return _MangaImageInspection(
        mimeType: 'image/webp',
        width: _readUint16LittleEndian(bytes, 26) & 0x3fff,
        height: _readUint16LittleEndian(bytes, 28) & 0x3fff,
      );
    }
    return null;
  }

  /// 判断图片尺寸是否同时满足单边和总像素上限。
  static bool _withinDimensionLimit(_MangaImageInspection inspection) {
    if (inspection.width <= 0 ||
        inspection.height <= 0 ||
        inspection.width > _maximumDimension ||
        inspection.height > _maximumDimension) {
      return false;
    }
    return inspection.width * inspection.height <= _maximumPixelCount;
  }

  /// 判断 JPEG 标记是否携带可读取尺寸的 SOF 段。
  static bool _isJpegStartOfFrame(int marker) {
    return <int>{
      0xc0,
      0xc1,
      0xc2,
      0xc3,
      0xc5,
      0xc6,
      0xc7,
      0xc9,
      0xca,
      0xcb,
      0xcd,
      0xce,
      0xcf,
    }.contains(marker);
  }

  /// 比较字节数组中指定位置是否匹配固定签名。
  static bool _matches(Uint8List bytes, int offset, List<int> signature) {
    if (offset < 0 || offset + signature.length > bytes.length) {
      return false;
    }
    for (int index = 0; index < signature.length; index += 1) {
      if (bytes[offset + index] != signature[index]) {
        return false;
      }
    }
    return true;
  }

  /// 比较字节数组中指定位置是否匹配 ASCII 签名。
  static bool _matchesAscii(Uint8List bytes, int offset, String value) {
    return _matches(bytes, offset, ascii.encode(value));
  }

  /// 读取大端 16 位无符号整数。
  static int _readUint16BigEndian(Uint8List bytes, int offset) {
    return (bytes[offset] << 8) | bytes[offset + 1];
  }

  /// 读取小端 16 位无符号整数。
  static int _readUint16LittleEndian(Uint8List bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  /// 读取大端 32 位无符号整数。
  static int _readUint32BigEndian(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  /// 读取小端 24 位无符号整数。
  static int _readUint24LittleEndian(Uint8List bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
  }
}

/// 从图片文件头读取出的格式和尺寸。
final class _MangaImageInspection {
  /// 创建内部图片检查结果。
  const _MangaImageInspection({
    required this.mimeType,
    required this.width,
    required this.height,
  });

  /// 文件头确认的 MIME。
  final String mimeType;

  /// 图片像素宽度。
  final int width;

  /// 图片像素高度。
  final int height;
}
