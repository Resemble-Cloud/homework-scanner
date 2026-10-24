import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fairscan_engine');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final engine = FairScanEngine();

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('scanImage 的 map 被解析成 ScanResult', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return <String, Object?>{
        'outputPath': '/data/scans/scan_9.jpg',
        'outputFormat': 'jpg',
        'sourceWidth': 4000,
        'sourceHeight': 3000,
        'outputWidth': 1414,
        'outputHeight': 1000,
        'fileBytes': 524288,
        'detected': true,
        'detectionStage': 'capture',
        'autoColorMode': 'GRAYSCALE',
        'colorMode': 'BLACK_AND_WHITE',
        'quad': [
          [1.0, 2.0],
          [3.0, 4.0],
          [5.0, 6.0],
          [7.0, 8.0],
        ],
        'timings': {
          'decodeMs': 100,
          'segmentationMs': 200,
          'detectionMs': 10,
          'colorModeMs': 5,
          'extractMs': 300,
          'encodeMs': 50,
          'totalMs': 700,
        },
      };
    });

    final result = await engine.scan(
      '/tmp/a.jpg',
      options: const ScanOptions(
        colorMode: ScanColorMode.blackAndWhite,
        maxPixels: 1000000,
        jpegQuality: 90,
      ),
    );

    expect(captured?.method, 'scanImage');
    expect(captured?.arguments, {
      'sourcePath': '/tmp/a.jpg',
      'colorMode': 'BLACK_AND_WHITE',
      'maxPixels': 1000000,
      'jpegQuality': 90,
      'shadowFlatten': true,
    });
    expect(result.outputPath, '/data/scans/scan_9.jpg');
    expect(result.outputWidth, 1414);
    expect(result.detected, isTrue);
    expect(result.detectionStage, 'capture');
    expect(result.colorMode, ScanColorMode.blackAndWhite);
    expect(result.autoColorMode, ScanColorMode.grayscale);
    expect(result.quad, hasLength(4));
    expect(result.quad!.first, (1.0, 2.0));
    expect(result.timings.totalMs, 700);
    expect(result.fileSizeLabel, '512 KB');
  });

  test('quad 以 4 组 [x, y] 对发送，而非扁平 8 个数字', () async {
    // Regression: the plugin's parseQuad rejects a flat [x1,y1,...,y4] list
    // with "四角坐标必须是 4 个点，实际 8 个". Sending flat broke both the
    // manual-crop editor and the detect-then-scan path on device.
    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return <String, Object?>{
        'outputPath': '/data/scans/scan_1.jpg',
        'outputFormat': 'jpg',
        'sourceWidth': 4000,
        'sourceHeight': 3000,
        'outputWidth': 1414,
        'outputHeight': 1000,
        'fileBytes': 524288,
        'detected': true,
        'detectionStage': 'manual',
        'autoColorMode': 'GRAYSCALE',
        'colorMode': 'GRAYSCALE',
        'quad': <List<num>>[],
        'timings': const <String, int>{'totalMs': 700},
      };
    });

    const quad = <NormalizedPoint>[
      (0.1, 0.2),
      (0.9, 0.3),
      (0.8, 0.9),
      (0.2, 0.7),
    ];

    await engine.scan('/tmp/a.jpg', options: const ScanOptions(quad: quad));
    final scanArgs = (captured!.arguments as Map)['quad'] as List;
    expect(scanArgs, hasLength(4));
    expect(scanArgs.first, [0.1, 0.2]);
    expect(scanArgs, isNot(contains(0.1))); // not a flat number list

    captured = null;
    await engine.cropImage('/tmp/a.jpg', quad);
    final cropArgs = (captured!.arguments as Map)['quad'] as List;
    expect(cropArgs, hasLength(4));
    expect(cropArgs.last, [0.2, 0.7]);
  });

  test('detectDocument 解析纸面外框候选及内容/背景指标', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'detectDocument');
      return <String, Object?>{
        'quad': [
          [0.2, 0.1],
          [0.8, 0.1],
          [0.8, 0.9],
          [0.2, 0.9],
        ],
        'score': 0.78,
        'meanProb': 0.94,
        'coverage': 0.62,
        'frameFill': 0.48,
        'detectionStage': 'capture',
        'sourceWidth': 3000,
        'sourceHeight': 4000,
        'segmentationMs': 200,
        'detectionMs': 20,
        'candidates': [
          {
            'source': 'capture',
            'quad': [
              [0.2, 0.1],
              [0.8, 0.1],
              [0.8, 0.9],
              [0.2, 0.9],
            ],
            'score': 0.78,
            'meanProb': 0.94,
            'coverage': 0.62,
            'frameFill': 0.48,
          },
          {
            'source': 'paper_outer',
            'quad': [
              [0.02, 0.02],
              [0.98, 0.02],
              [0.98, 0.98],
              [0.02, 0.98],
            ],
            'score': 0.7,
            'meanProb': 0.75,
            'coverage': 0.99,
            'frameFill': 0.92,
          },
          {
            'source': 'default',
            'quad': [
              [0.02, 0.02],
              [0.98, 0.02],
              [0.98, 0.98],
              [0.02, 0.98],
            ],
            'score': 0.5,
            'meanProb': 0.75,
            'coverage': 1.0,
            'frameFill': 0.92,
          },
        ],
      };
    });

    final detection = await engine.detectDocument('/tmp/page.jpg');
    expect(detection.candidates, hasLength(3));
    expect(detection.candidates[1].source, 'paper_outer');
    expect(detection.candidates[1].coverage, closeTo(0.99, 1e-9));
    expect(detection.candidates[1].background, closeTo(0.25, 1e-9));
    expect(detection.candidates[1].usable, isTrue);
  });

  test('shadowFlatten 开关随 scan 参数发送', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return <String, Object?>{
        'outputPath': '/data/scans/scan_1.jpg',
        'outputFormat': 'jpg',
        'sourceWidth': 10,
        'sourceHeight': 10,
        'outputWidth': 10,
        'outputHeight': 10,
        'fileBytes': 1,
        'detected': true,
        'detectionStage': 'manual',
        'autoColorMode': 'GRAYSCALE',
        'colorMode': 'GRAYSCALE',
        'quad': <List<num>>[],
        'timings': const <String, int>{},
      };
    });

    await engine.scan(
      '/tmp/a.jpg',
      options: const ScanOptions(shadowFlatten: false),
    );
    expect((captured!.arguments as Map)['shadowFlatten'], isFalse);
  });

  test('PlatformException 被转换成带错误码的 ScanEngineException', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'DECODE_FAILED', message: '无法解码图片');
    });

    await expectLater(
      engine.scan('/tmp/broken.jpg'),
      throwsA(
        isA<ScanEngineException>()
            .having((e) => e.code, 'code', 'DECODE_FAILED')
            .having((e) => e.message, 'message', '无法解码图片'),
      ),
    );
  });

  test('engineInfo 解析模型与 OpenCV 版本', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'engineInfo');
      return <String, Object?>{
        'modelAsset': 'fairscan-segmentation-model.tflite',
        'opencvVersion': '4.12.0',
        'initialized': false,
      };
    });

    final info = await engine.engineInfo();
    expect(info.modelAsset, 'fairscan-segmentation-model.tflite');
    expect(info.opencvVersion, '4.12.0');
    expect(info.initialized, isFalse);
  });
}
