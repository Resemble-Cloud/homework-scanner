import 'dart:io';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homework_scanner/main.dart';
import 'package:homework_scanner/models/scan_document.dart';
import 'package:homework_scanner/services/document_controller.dart';
import 'package:homework_scanner/services/session_store.dart';

import 'support/fakes.dart';

void main() {
  late Directory temp;
  late SessionStore store;
  late FakeScanEngine engine;
  late RecordingPdfExporter exporter;
  late DocumentController controller;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('scanner_widget_test_');
    store = SyncSessionStore(root: temp);
    engine = FakeScanEngine(
      fixturePath: fixtureJpegPath(),
      outputDir: Directory('${temp.path}/native'),
    );
    exporter = RecordingPdfExporter();
    controller = DocumentController(
      engine: engine,
      store: store,
      exporter: exporter,
      defaultColorMode: ScanColorMode.grayscale,
    );
    await controller.initialize();
  });

  tearDown(() async {
    controller.dispose();
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } catch (_) {
      // Image cache may still hold a test JPEG on Windows; the temp folder is
      // disposable and the OS will reclaim it.
    }
  });

  void setUpView(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    setUpView(tester);
    await tester.pumpWidget(HomeworkScannerApp(controller: controller));
    // The grid has no indeterminate animation once all pages are done. Pump
    // explicit frames so a regression fails an assertion rather than hanging
    // in pumpAndSettle's ten-minute window.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Controller work uses real file I/O; run it outside the fake-async zone.
  Future<List<ScanPage>> addPages(WidgetTester tester, int count) async {
    final pages = await tester.runAsync(() async {
      final added = <ScanPage>[];
      for (var i = 0; i < count; i++) {
        added.add(await controller.addCapturedPage(fixtureJpegPath()));
      }
      await controller.waitForIdle();
      return added;
    });
    expect(controller.document!.pages.every((p) => p.isDone), isTrue);
    return pages!;
  }

  testWidgets('有页面时显示页面网格、编号与处理状态', (tester) async {
    final pages = await addPages(tester, 2);
    await pumpApp(tester);

    expect(find.text('作业扫描'), findsOneWidget);
    expect(find.byKey(Key('page-tile-${pages[0].id}')), findsOneWidget);
    expect(find.byKey(Key('page-tile-${pages[1].id}')), findsOneWidget);
    expect(find.text('全部 2 页处理完成'), findsOneWidget);
    expect(find.text('已完成'), findsNWidgets(2));
  });

  testWidgets('长按拖动页面可以改变顺序', (tester) async {
    final pages = await addPages(tester, 3);
    await pumpApp(tester);

    final start = tester.getCenter(find.byKey(Key('page-tile-${pages[0].id}')));
    final target = tester.getCenter(
      find.byKey(Key('page-tile-${pages[2].id}')),
    );
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(target);
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.document!.pages.map((page) => page.id), [
      pages[1].id,
      pages[2].id,
      pages[0].id,
    ]);
  });

  testWidgets('低置信页面出现建议检查并可进入四角修正', (tester) async {
    engine.detection = DetectResult(
      quad: const [(0.3, 0.1), (0.7, 0.1), (0.7, 0.9), (0.3, 0.9)],
      score: 0.42,
      meanProb: 0.95,
      coverage: 0.9,
      frameFill: 0.22,
      detectionStage: 'capture',
      sourceWidth: 900,
      sourceHeight: 1200,
      segmentationMs: 40,
      detectionMs: 5,
    );
    final pages = await addPages(tester, 1);
    await pumpApp(tester);

    expect(find.text('建议检查'), findsOneWidget);
    await tester.tap(find.byKey(Key('page-tile-${pages.single.id}')));
    await pumpFrames(tester);
    // The grid tile remains in the route stack underneath the detail page.
    expect(find.text('建议检查'), findsWidgets);
    expect(find.byKey(const Key('review-correct-button')), findsOneWidget);
  });

  testWidgets('失败页显示失败标记，详情提供重试入口', (tester) async {
    engine.failScansRemaining = 1;
    final pages = await tester.runAsync(() async {
      final page = await controller.addCapturedPage(fixtureJpegPath());
      await controller.waitForIdle();
      return page;
    });
    await pumpApp(tester);

    expect(find.text('处理失败 · 点按重试'), findsOneWidget);
    await tester.tap(find.byKey(Key('page-tile-${pages!.id}')));
    await pumpFrames(tester);
    expect(find.byKey(const Key('retry-page-button')), findsOneWidget);
    expect(find.text('处理失败，原图未修改'), findsOneWidget);
  });

  testWidgets('导出对话框带默认文件名并可关闭适配 A4', (tester) async {
    await addPages(tester, 2);
    setUpView(tester);
    await tester.pumpWidget(HomeworkScannerApp(controller: controller));
    await pumpFrames(tester);

    await tester.tap(find.byKey(const Key('export-button')));
    await pumpFrames(tester);
    expect(find.text('导出 PDF'), findsOneWidget);

    final field = tester.widget<TextField>(
      find.byKey(const Key('pdf-name-field')),
    );
    expect(field.controller!.text, startsWith('扫描_'));
    expect(find.text('2 页 · 处理后的图片直接嵌入，不二次压缩'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pdf-name-field')), '作业_验收');
    await tester.tap(find.byKey(const Key('fit-a4-checkbox')));
    await tester.pump();
    final checkbox = tester.widget<CheckboxListTile>(
      find.byKey(const Key('fit-a4-checkbox')),
    );
    expect(checkbox.value, isFalse);

    await tester.tap(find.text('取消'));
    await pumpFrames(tester);
    expect(find.text('导出 PDF'), findsNothing);
    // Actual export invocation/ordering is covered by the controller test.
    expect(exporter.calls, 0);
  });
}
