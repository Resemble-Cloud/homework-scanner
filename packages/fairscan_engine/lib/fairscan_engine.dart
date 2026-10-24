import 'dart:io';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Colour handling for the scan, mirroring FairScan's `ColorMode`.
enum ScanColorMode {
  /// FairScan's automatic detection (chroma based).
  auto('AUTO'),
  color('COLOR'),
  grayscale('GRAYSCALE'),
  blackAndWhite('BLACK_AND_WHITE');

  const ScanColorMode(this.wireName);

  final String wireName;

  static ScanColorMode fromWire(String? value) {
    return ScanColorMode.values.firstWhere(
      (mode) => mode.wireName == value?.toUpperCase(),
      orElse: () => ScanColorMode.auto,
    );
  }
}

/// A normalized [0,1] image point. `(0,0)` is the top-left corner.
typedef NormalizedPoint = (double, double);

/// Options forwarded to the native engine.
@immutable
class ScanOptions {
  const ScanOptions({
    this.colorMode = ScanColorMode.auto,
    this.maxPixels = 2000000,
    this.jpegQuality = 80,
    this.quad,
    this.shadowFlatten = true,
  });

  final ScanColorMode colorMode;

  /// Apply the native, conservative low-frequency shadow pass.
  final bool shadowFlatten;

  /// Pixel budget of the processed page (FairScan's BALANCED quality is 2 MP).
  final int maxPixels;
  final int jpegQuality;

  /// Optional user-corrected quad in normalized `[0,1]` coordinates, corner
  /// order top-left, top-right, bottom-right, bottom-left. When set, it wins
  /// over automatic detection so a bad frame can't drop formulas again.
  final List<NormalizedPoint>? quad;

  Map<String, Object?> toMap() => <String, Object?>{
    'colorMode': colorMode.wireName,
    'maxPixels': maxPixels,
    'jpegQuality': jpegQuality,
    'shadowFlatten': shadowFlatten,
    if (quad != null)
      // Nested [x, y] pairs — the plugin's parseQuad rejects a flat list.
      'quad': quad!.map((p) => <num>[p.$1, p.$2]).toList(growable: false),
  };
}

/// Where the time went, measured natively in milliseconds.
@immutable
class ScanStageTimings {
  const ScanStageTimings({
    required this.decodeMs,
    required this.segmentationMs,
    required this.detectionMs,
    required this.colorModeMs,
    required this.extractMs,
    required this.encodeMs,
    required this.totalMs,
  });

  factory ScanStageTimings.fromMap(Map<dynamic, dynamic> map) {
    int read(String key) => (map[key] as num?)?.toInt() ?? 0;
    return ScanStageTimings(
      decodeMs: read('decodeMs'),
      segmentationMs: read('segmentationMs'),
      detectionMs: read('detectionMs'),
      colorModeMs: read('colorModeMs'),
      extractMs: read('extractMs'),
      encodeMs: read('encodeMs'),
      totalMs: read('totalMs'),
    );
  }

  final int decodeMs;
  final int segmentationMs;
  final int detectionMs;
  final int colorModeMs;
  final int extractMs;
  final int encodeMs;
  final int totalMs;

  List<(String, int)> get entries => <(String, int)>[
    ('解码', decodeMs),
    ('分割推理', segmentationMs),
    ('纸张检测', detectionMs),
    ('色彩判定', colorModeMs),
    ('透视+增强', extractMs),
    ('编码', encodeMs),
    ('总计', totalMs),
  ];
}

/// A successfully written scan.
@immutable
class ScanResult {
  const ScanResult({
    required this.outputPath,
    required this.outputFormat,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.outputWidth,
    required this.outputHeight,
    required this.fileBytes,
    required this.detected,
    required this.detectionStage,
    required this.autoColorMode,
    required this.colorMode,
    required this.quad,
    required this.timings,
  });

  factory ScanResult.fromMap(Map<dynamic, dynamic> map) {
    int read(String key) => (map[key] as num?)?.toInt() ?? 0;
    final rawQuad = map['quad'];
    return ScanResult(
      outputPath: map['outputPath'] as String,
      outputFormat: map['outputFormat'] as String? ?? 'jpg',
      sourceWidth: read('sourceWidth'),
      sourceHeight: read('sourceHeight'),
      outputWidth: read('outputWidth'),
      outputHeight: read('outputHeight'),
      fileBytes: read('fileBytes'),
      detected: map['detected'] as bool? ?? false,
      detectionStage: map['detectionStage'] as String? ?? 'none',
      autoColorMode: ScanColorMode.fromWire(map['autoColorMode'] as String?),
      colorMode: ScanColorMode.fromWire(map['colorMode'] as String?),
      quad: rawQuad is List
          ? rawQuad
                .whereType<List<dynamic>>()
                .map(
                  (point) => (
                    (point[0] as num).toDouble(),
                    (point[1] as num).toDouble(),
                  ),
                )
                .toList(growable: false)
          : null,
      timings: ScanStageTimings.fromMap(
        (map['timings'] as Map<dynamic, dynamic>?) ?? const <String, int>{},
      ),
    );
  }

  final String outputPath;
  final String outputFormat;
  final int sourceWidth;
  final int sourceHeight;
  final int outputWidth;
  final int outputHeight;
  final int fileBytes;
  final bool detected;

  /// `import`, `capture`, `manual` or `none` — where the quad came from.
  final String detectionStage;
  final ScanColorMode autoColorMode;
  final ScanColorMode colorMode;
  final List<(double, double)>? quad;
  final ScanStageTimings timings;

  String get fileSizeLabel {
    if (fileBytes >= 1024 * 1024) {
      return '${(fileBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(fileBytes / 1024).toStringAsFixed(0)} KB';
  }
}

@immutable
class EngineInfo {
  const EngineInfo({
    required this.modelAsset,
    required this.opencvVersion,
    required this.initialized,
  });

  factory EngineInfo.fromMap(Map<dynamic, dynamic> map) => EngineInfo(
    modelAsset: map['modelAsset'] as String? ?? 'unknown',
    opencvVersion: map['opencvVersion'] as String? ?? 'unknown',
    initialized: map['initialized'] as bool? ?? false,
  );

  final String modelAsset;
  final String opencvVersion;
  final bool initialized;
}

/// One crop candidate produced by the native detector.
///
/// The controller compares [coverage] (paper content kept) and
/// [background] (non-paper share inside the crop) before choosing a quad.
@immutable
class QuadCandidate {
  const QuadCandidate({
    required this.source,
    required this.quad,
    required this.score,
    required this.meanProb,
    required this.coverage,
    required this.frameFill,
  });

  factory QuadCandidate.fromMap(Map<dynamic, dynamic> map) {
    final rawQuad = map['quad'];
    return QuadCandidate(
      source: map['source'] as String? ?? 'default',
      quad: rawQuad is List
          ? rawQuad
                .whereType<List<dynamic>>()
                .map(
                  (point) => (
                    (point[0] as num).toDouble(),
                    (point[1] as num).toDouble(),
                  ),
                )
                .toList(growable: false)
          : const <NormalizedPoint>[],
      score: (map['score'] as num?)?.toDouble() ?? 0.0,
      meanProb: (map['meanProb'] as num?)?.toDouble() ?? 0.0,
      coverage: (map['coverage'] as num?)?.toDouble() ?? 0.0,
      frameFill: (map['frameFill'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// `import`, `capture`, `paper_outer` or `default`.
  final String source;
  final List<NormalizedPoint> quad;
  final double score;
  final double meanProb;

  /// Share of the visible paper mask kept by this quad.
  final double coverage;
  final double frameFill;

  double get background => (1.0 - meanProb).clamp(0.0, 1.0);

  bool get usable => quad.length == 4 && coverage >= 0.97 && frameFill >= 0.50;

  Map<String, Object?> toMap() => <String, Object?>{
    'source': source,
    'quad': quad
        .map((point) => <double>[point.$1, point.$2])
        .toList(growable: false),
    'score': score,
    'meanProb': meanProb,
    'coverage': coverage,
    'frameFill': frameFill,
  };
}

/// Result of the detection-only call, which skips warp/enhance.
@immutable
class DetectResult {
  const DetectResult({
    required this.quad,
    required this.score,
    this.meanProb,
    this.coverage,
    this.frameFill,
    required this.detectionStage,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.segmentationMs,
    required this.detectionMs,
    this.candidates = const <QuadCandidate>[],
  });

  factory DetectResult.fromMap(Map<dynamic, dynamic> map) {
    final rawQuad = map['quad'];
    final rawCandidates = map['candidates'];
    return DetectResult(
      quad: rawQuad is List
          ? rawQuad
                .whereType<List<dynamic>>()
                .map(
                  (point) => (
                    (point[0] as num).toDouble(),
                    (point[1] as num).toDouble(),
                  ),
                )
                .toList(growable: false)
          : null,
      score: (map['score'] as num?)?.toDouble() ?? 0.0,
      meanProb: (map['meanProb'] as num?)?.toDouble(),
      coverage: (map['coverage'] as num?)?.toDouble(),
      frameFill: (map['frameFill'] as num?)?.toDouble(),
      detectionStage: map['detectionStage'] as String? ?? 'none',
      sourceWidth: (map['sourceWidth'] as num?)?.toInt() ?? 0,
      sourceHeight: (map['sourceHeight'] as num?)?.toInt() ?? 0,
      segmentationMs: (map['segmentationMs'] as num?)?.toInt() ?? 0,
      detectionMs: (map['detectionMs'] as num?)?.toInt() ?? 0,
      candidates: rawCandidates is List
          ? rawCandidates
                .whereType<Map<dynamic, dynamic>>()
                .map(QuadCandidate.fromMap)
                .toList(growable: false)
          : const <QuadCandidate>[],
    );
  }

  /// Normalized `[0,1]` quad (top-left, top-right, bottom-right, bottom-left), or null.
  final List<NormalizedPoint>? quad;

  /// Combined confidence, 0..1: paper fill inside the frame x how much of the
  /// visible page the frame covers. Low means the frame probably clipped page
  /// content, so the user should drag the corners.
  final double score;

  /// Mean paper probability inside the quad (the "is this all page?" half of
  /// [score]); null when the native side did not report it.
  final double? meanProb;

  /// Share of the model's paper mask the quad covers (the "is the whole page
  /// in frame?" half of [score]); null when not reported.
  final double? coverage;

  /// Share of the photo the quad covers. A value far below half means the
  /// frame grabbed a strip of the page rather than the page itself.
  final double? frameFill;

  /// `import`, `capture` or `none`.
  final String detectionStage;
  final int sourceWidth;
  final int sourceHeight;
  final int segmentationMs;
  final int detectionMs;

  /// Native crop candidates. Older engines/tests may leave this empty; the
  /// controller then synthesizes the legacy detected + full-frame candidates.
  final List<QuadCandidate> candidates;

  bool get detected => quad != null;

  /// Decodes [sourcePath], draws the detected quad as a red outline (scaled to
  /// the image's native pixels) and returns the result as PNG bytes. Used to
  /// archive the detection overlay so a clipped frame is visible in review.
  /// Returns null when the quad is missing or the image cannot be decoded.
  Future<Uint8List?> renderQuadOverlay(
    String sourcePath, {
    Color outline = const Color(0xFFE53935),
    double strokeWidth = 6,
  }) async {
    final points = quad;
    if (points == null || points.length != 4) return null;
    final bytes = await File(sourcePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    codec.dispose();
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      );
      canvas.drawImage(image, Offset.zero, Paint());
      final path = Path()
        ..moveTo(points[0].$1 * image.width, points[0].$2 * image.height);
      for (var i = 1; i < points.length; i++) {
        path.lineTo(points[i].$1 * image.width, points[i].$2 * image.height);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
      final picture = recorder.endRecording();
      final out = await picture.toImage(image.width, image.height);
      final png = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      picture.dispose();
      return png?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}

/// Result of re-cropping with a user-corrected quad.
@immutable
class CropResult {
  const CropResult({
    required this.outputPath,
    required this.outputFormat,
    required this.outputWidth,
    required this.outputHeight,
    required this.fileBytes,
    required this.colorMode,
    required this.timings,
  });

  factory CropResult.fromMap(Map<dynamic, dynamic> map) => CropResult(
    outputPath: map['outputPath'] as String,
    outputFormat: map['outputFormat'] as String? ?? 'jpg',
    outputWidth: (map['outputWidth'] as num?)?.toInt() ?? 0,
    outputHeight: (map['outputHeight'] as num?)?.toInt() ?? 0,
    fileBytes: (map['fileBytes'] as num?)?.toInt() ?? 0,
    colorMode: ScanColorMode.fromWire(map['colorMode'] as String?),
    timings: ScanStageTimings.fromMap(
      (map['timings'] as Map<dynamic, dynamic>?) ?? const <String, int>{},
    ),
  );

  final String outputPath;
  final String outputFormat;
  final int outputWidth;
  final int outputHeight;
  final int fileBytes;
  final ScanColorMode colorMode;
  final ScanStageTimings timings;

  String get fileSizeLabel {
    if (fileBytes >= 1024 * 1024) {
      return '${(fileBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(fileBytes / 1024).toStringAsFixed(0)} KB';
  }
}

/// Failure reported by the native engine. [code] is a stable machine token.
class ScanEngineException implements Exception {
  const ScanEngineException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ScanEngineException($code): $message';
}

/// Contract used by the UI and by tests.
abstract interface class ScanEngine {
  Future<EngineInfo> engineInfo();

  Future<void> initialize();

  Future<ScanResult> scan(String sourcePath, {ScanOptions options});

  Future<DetectResult> detectDocument(String sourcePath);

  Future<CropResult> cropImage(
    String sourcePath,
    List<NormalizedPoint> quad, {
    ScanOptions options,
  });
}

/// MethodChannel client for the Android `fairscan_engine` plugin.
class FairScanEngine implements ScanEngine {
  FairScanEngine({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('fairscan_engine');

  final MethodChannel _channel;

  @override
  Future<EngineInfo> engineInfo() async {
    final map = await _invoke<Map<dynamic, dynamic>>('engineInfo');
    return EngineInfo.fromMap(map);
  }

  @override
  Future<void> initialize() async {
    await _invoke<bool>('initialize');
  }

  @override
  Future<ScanResult> scan(
    String sourcePath, {
    ScanOptions options = const ScanOptions(),
  }) async {
    final map = await _invoke<Map<dynamic, dynamic>>(
      'scanImage',
      <String, Object?>{'sourcePath': sourcePath, ...options.toMap()},
    );
    return ScanResult.fromMap(map);
  }

  @override
  Future<DetectResult> detectDocument(String sourcePath) async {
    final map = await _invoke<Map<dynamic, dynamic>>(
      'detectDocument',
      <String, Object?>{'sourcePath': sourcePath},
    );
    return DetectResult.fromMap(map);
  }

  @override
  Future<CropResult> cropImage(
    String sourcePath,
    List<NormalizedPoint> quad, {
    ScanOptions options = const ScanOptions(),
  }) async {
    final map = await _invoke<Map<dynamic, dynamic>>('cropImage', <
      String,
      Object?
    >{
      'sourcePath': sourcePath,
      // `..remove('quad')` drops the flattened quad from options.toMap(); this
      // explicit key is the canonical serialization the plugin expects.
      ...options.toMap()..remove('quad'),
      'quad': quad.map((p) => <num>[p.$1, p.$2]).toList(growable: false),
    });
    return CropResult.fromMap(map);
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _channel.invokeMethod<T>(method, args);
      if (result == null) {
        throw ScanEngineException('ENGINE_EMPTY_RESULT', '原生引擎返回了空结果: $method');
      }
      return result;
    } on PlatformException catch (error) {
      throw ScanEngineException(
        error.code,
        error.message ?? '原生处理失败 (${error.code})',
      );
    } on MissingPluginException {
      throw const ScanEngineException(
        'ENGINE_UNAVAILABLE',
        '扫描引擎未注册，请检查 fairscan_engine 插件是否已链接',
      );
    }
  }
}
