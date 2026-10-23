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

/// Options forwarded to the native engine.
@immutable
class ScanOptions {
  const ScanOptions({
    this.colorMode = ScanColorMode.auto,
    this.maxPixels = 2000000,
    this.jpegQuality = 80,
  });

  final ScanColorMode colorMode;

  /// Pixel budget of the processed page (FairScan's BALANCED quality is 2 MP).
  final int maxPixels;
  final int jpegQuality;

  Map<String, Object?> toMap() => <String, Object?>{
    'colorMode': colorMode.wireName,
    'maxPixels': maxPixels,
    'jpegQuality': jpegQuality,
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

  /// `import`, `capture` or `none` — which detection entry point produced the quad.
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
    final map = await _invoke<Map<dynamic, dynamic>>('scanImage', <
      String,
      Object?
    >{
      'sourcePath': sourcePath,
      ...options.toMap(),
    });
    return ScanResult.fromMap(map);
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _channel.invokeMethod<T>(method, args);
      if (result == null) {
        throw ScanEngineException(
          'ENGINE_EMPTY_RESULT',
          '原生引擎返回了空结果: $method',
        );
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
