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
  ScanOptions? lastOptions;

  @override
  Future<EngineInfo> engineInfo() async => const EngineInfo(
    modelAsset: 'fairscan-segmentation-model.tflite',
    opencvVersion: '4.12.0',
    initialized: true,
  );

  @override
  Future<void> initialize() async {}

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
}
