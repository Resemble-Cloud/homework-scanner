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
