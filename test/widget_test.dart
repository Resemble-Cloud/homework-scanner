import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homework_scanner/main.dart';

const _timings = ScanStageTimings(
  decodeMs: 120,
  segmentationMs: 260,
  detectionMs: 18,
  colorModeMs: 12,
  extractMs: 410,
  encodeMs: 60,
  totalMs: 900,
);

ScanResult _result({
  String outputPath = '/data/user/0/app/files/scans/scan_1.jpg',
}) => ScanResult(
  outputPath: outputPath,
  outputFormat: 'jpg',
  sourceWidth: 4000,
  sourceHeight: 3000,
  outputWidth: 1400,
  outputHeight: 1050,
  fileBytes: 320 * 1024,
  detected: true,
  detectionStage: 'import',
  autoColorMode: ScanColorMode.grayscale,
  colorMode: ScanColorMode.grayscale,
  quad: const [(10.0, 20.0), (3900.0, 30.0), (3890.0, 2980.0), (20.0, 2970.0)],
  timings: _timings,
);

class _FakeEngine implements ScanEngine {
  _FakeEngine({this.error});

  final ScanEngineException? error;
  int scanCount = 0;
  int detectCount = 0;
  ScanOptions? lastOptions;

  /// Returned by [detectDocument]; defaults to a high-confidence frame so the
  /// happy-path tests do not open the corner editor.
  DetectResult detectResult = const DetectResult(
    quad: [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)],
    score: 0.97,
    meanProb: 0.98,
    coverage: 0.99,
    frameFill: 0.8,
    detectionStage: 'import',
    sourceWidth: 3000,
    sourceHeight: 4000,
    segmentationMs: 260,
    detectionMs: 18,
  );

  @override
  Future<EngineInfo> engineInfo() async => const EngineInfo(
    modelAsset: 'fairscan-segmentation-model.tflite',
    opencvVersion: '4.12.0',
    initialized: true,
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<DetectResult> detectDocument(String sourcePath) async {
    detectCount++;
    final failure = error;
    if (failure != null) throw failure;
    return detectResult;
  }

  @override
  Future<ScanResult> scan(
    String sourcePath, {
    ScanOptions options = const ScanOptions(),
  }) async {
    scanCount++;
    lastOptions = options;
    final failure = error;
    if (failure != null) throw failure;
    return _result();
  }

  @override
  Future<CropResult> cropImage(
    String sourcePath,
    List<NormalizedPoint> quad, {
    ScanOptions options = const ScanOptions(),
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    return CropResult(
      outputPath: '/data/user/0/app/files/crops/crop_1.jpg',
      outputFormat: 'jpg',
      outputWidth: 1400,
      outputHeight: 1050,
      fileBytes: 300 * 1024,
      colorMode: ScanColorMode.grayscale,
      timings: _timings,
    );
  }
}

Future<void> _pumpApp(
  WidgetTester tester,
  _FakeEngine engine, {
  Future<String?> Function()? picker,
}) async {
  // Tall surface so the result cards are laid out even without scrolling.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 2600);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HomeworkScannerApp(
      engine: engine,
      pickImage: picker ?? () async => '/tmp/homework.jpg',
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('扫描成功后展示原图、结果、耗时与输出信息', (tester) async {
    final engine = _FakeEngine();
    await _pumpApp(tester, engine);

    expect(find.textContaining('fairscan-segmentation-model.tflite'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    expect(engine.scanCount, 1);
    expect(find.byKey(const Key('source-image')), findsOneWidget);
    expect(find.byKey(const Key('result-image')), findsOneWidget);
    expect(find.textContaining('1400×1050'), findsWidgets);
    expect(find.textContaining('320 KB'), findsOneWidget);
    expect(find.textContaining('成功（import）'), findsOneWidget);
    expect(find.textContaining('900 ms'), findsOneWidget);
    // Confidence is split on screen so a frame that grabbed a strip of the page
    // is diagnosable from a screenshot.
    expect(find.textContaining('0.800'), findsOneWidget);
  });

  testWidgets('原生失败时展示错误码且保留原图路径', (tester) async {
    final engine = _FakeEngine(
      error: const ScanEngineException('DECODE_FAILED', '无法解码图片: broken.jpg'),
    );
    await _pumpApp(tester, engine);

    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    expect(find.text('处理失败'), findsOneWidget);
    expect(find.textContaining('DECODE_FAILED: 无法解码图片'), findsOneWidget);
    expect(find.text('原图未被修改。'), findsOneWidget);
    expect(find.byKey(const Key('result-image')), findsNothing);
  });

  testWidgets('取消选择时不调用引擎', (tester) async {
    final engine = _FakeEngine();
    await _pumpApp(tester, engine, picker: () async => null);

    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    expect(engine.scanCount, 0);
    expect(find.text('处理失败'), findsNothing);
  });

  testWidgets('色彩模式随选项传入引擎', (tester) async {
    final engine = _FakeEngine();
    await _pumpApp(tester, engine);

    await tester.tap(find.byType(DropdownButtonFormField<ScanColorMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('黑白（二值化）').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    expect(engine.lastOptions?.colorMode, ScanColorMode.blackAndWhite);
  });

  testWidgets('4MP 档位随选项传入引擎', (tester) async {
    final engine = _FakeEngine();
    await _pumpApp(tester, engine);

    // Default is already 4MP (Sprint 1: keep sub/superscripts legible).
    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    expect(engine.lastOptions?.maxPixels, 4000000);

    await tester.tap(find.text('平衡 2MP'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    expect(engine.lastOptions?.maxPixels, 2000000);
  });

  testWidgets('检测先行：高置信度直接扫描，不再走四角编辑', (tester) async {
    final engine = _FakeEngine();
    await _pumpApp(tester, engine);

    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    expect(engine.detectCount, 1);
    expect(engine.scanCount, 1);
    expect(find.byKey(const Key('apply-quad-button')), findsNothing);
    expect(engine.lastOptions?.quad, isNotNull);
  });

  testWidgets('检测置信度偏低时打开四角编辑器', (tester) async {
    final engine = _FakeEngine()
      ..detectResult = const DetectResult(
        quad: [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)],
        score: 0.42,
        detectionStage: 'capture',
        sourceWidth: 3000,
        sourceHeight: 4000,
        segmentationMs: 260,
        detectionMs: 30,
      );
    await _pumpApp(tester, engine);

    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    // Auto scan is held back until the user confirms the frame.
    expect(engine.scanCount, 0);
    expect(find.byKey(const Key('apply-quad-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('apply-quad-button')));
    await tester.pumpAndSettle();

    expect(engine.scanCount, 1);
  });

  testWidgets('检测框只占取景框一小部分时强制确认四角', (tester) async {
    // Sample 2.jpg: the frame was 100% paper but only covered a strip of the
    // photo, so the interior score alone looked fine.
    final engine = _FakeEngine()
      ..detectResult = const DetectResult(
        quad: [(0.3, 0.1), (0.7, 0.1), (0.7, 0.9), (0.3, 0.9)],
        // The engine's 0.95 paper fill is dragged down by the 22% frame fill.
        score: 0.78,
        meanProb: 0.95,
        coverage: 0.9,
        frameFill: 0.22,
        detectionStage: 'capture',
        sourceWidth: 3000,
        sourceHeight: 4000,
        segmentationMs: 260,
        detectionMs: 40,
      );
    await _pumpApp(tester, engine);

    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    expect(engine.scanCount, 0);
    expect(find.byKey(const Key('apply-quad-button')), findsOneWidget);
    expect(find.textContaining('取景框 22%'), findsOneWidget);
  });

  testWidgets('未检出纸张时同样进入四角编辑器', (tester) async {
    final engine = _FakeEngine()
      ..detectResult = const DetectResult(
        quad: null,
        score: 0.0,
        detectionStage: 'none',
        sourceWidth: 3000,
        sourceHeight: 4000,
        segmentationMs: 260,
        detectionMs: 22,
      );
    await _pumpApp(tester, engine);

    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();

    expect(engine.scanCount, 0);
    expect(find.byKey(const Key('apply-quad-button')), findsOneWidget);
  });

  testWidgets('手动调整四角按钮打开编辑器并把 quad 传给引擎', (tester) async {
    final engine = _FakeEngine();
    await _pumpApp(tester, engine);

    await tester.tap(find.byKey(const Key('pick-button')));
    await tester.pumpAndSettle();
    final autoQuad = engine.lastOptions?.quad;
    expect(autoQuad, isNotNull);

    await tester.tap(find.text('手动调整四角'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('apply-quad-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('apply-quad-button')));
    await tester.pumpAndSettle();

    expect(engine.scanCount, 2);
    expect(engine.lastOptions?.quad, isNotNull);
  });
}
