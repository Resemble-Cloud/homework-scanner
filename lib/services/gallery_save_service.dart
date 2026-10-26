import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Outcome of [GallerySaveService.saveImage].
class GallerySaveResult {
  const GallerySaveResult.success({required this.savedPath})
    : ok = true,
      code = null,
      message = null;

  const GallerySaveResult.shareFallback()
    : ok = false,
      code = 'share_fallback',
      savedPath = null,
      message = null;

  const GallerySaveResult.failure(this.code, this.message)
    : ok = false,
      savedPath = null;

  /// True when the file landed in the system gallery.
  final bool ok;

  /// Machine readable failure reason; `share_fallback` means Android < 10.
  final String? code;

  /// Gallery relative path, e.g. `Pictures/作业扫描/作业扫描_....jpg`.
  final String? savedPath;

  final String? message;

  /// Android 9 and below cannot write the gallery without a storage permission
  /// the app deliberately does not hold, so the caller opens the system share
  /// sheet instead.
  bool get needsShareSheet => code == 'share_fallback';
}

/// Writes one already-processed page image into the Android gallery.
///
/// The channel lives in `MainActivity`; it rejects missing/non-image sources,
/// sanitizes the requested file name and only ever writes to
/// `Pictures/作业扫描`.
class GallerySaveService {
  static const MethodChannel channel = MethodChannel(
    'homework_scanner/gallery',
  );

  /// [path] must be the processed image; the original photo never goes to the
  /// gallery. [fileName] is the requested display name.
  Future<GallerySaveResult> saveImage(
    String path, {
    required String fileName,
  }) async {
    Object? response;
    try {
      response = await channel.invokeMethod<Object>('saveImage', <String, Object?>{
        'path': path,
        'fileName': fileName,
      });
    } on PlatformException catch (error) {
      return GallerySaveResult.failure(
        error.code,
        error.message ?? '原生保存失败',
      );
    } on MissingPluginException {
      return GallerySaveResult.failure(
        'unimplemented',
        '当前平台不支持直接保存到相册',
      );
    }
    if (response is! Map) {
      return const GallerySaveResult.failure('bad_response', '原生返回格式错误');
    }
    final map = response.cast<String, Object?>();
    if (map['ok'] == true) {
      return GallerySaveResult.success(
        savedPath: map['savedPath'] as String? ?? '',
      );
    }
    final code = map['code'] as String? ?? 'unknown';
    if (code == 'share_fallback') return const GallerySaveResult.shareFallback();
    return GallerySaveResult.failure(
      code,
      map['message'] as String? ?? '保存到相册失败',
    );
  }

  /// `作业扫描_<yyyyMMdd_HHmmss>_第N页.jpg` / `.png`, driven by the real
  /// output file so a black-and-white PNG keeps its `.png` extension.
  static String fileNameFor(String sourcePath, int pageNumber, {DateTime? now}) {
    final stamp = now ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final time =
        '${stamp.year}${two(stamp.month)}${two(stamp.day)}_'
        '${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}';
    return '作业扫描_${time}_第$pageNumber页${extensionFor(sourcePath)}';
  }

  /// Returns `.jpg` or `.png` for a real output file, `null` otherwise.
  static String? extensionFor(String path) => switch (
      p.extension(path).toLowerCase()
    ) {
      '.png' => '.png',
      '.jpg' => '.jpg',
      '.jpeg' => '.jpg',
      _ => null,
    };

  /// MIME type for a real output file, or `null` when it is not an image the
  /// gallery channel accepts.
  static String? mimeTypeFor(String path) => switch (extensionFor(path)) {
    '.png' => 'image/png',
    '.jpg' => 'image/jpeg',
    _ => null,
  };
}
