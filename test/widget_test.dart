import 'dart:io';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homework_scanner/main.dart';
import 'package:homework_scanner/models/scan_document.dart';
import 'package:homework_scanner/models/scan_settings.dart';
import 'package:homework_scanner/services/document_controller.dart';
import 'package:homework_scanner/services/session_store.dart';
import 'package:homework_scanner/services/settings_store.dart';

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

  Future<void> pumpFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpApp(WidgetTester tester, {bool openDocument = true}) async {
    setUpView(tester);
    await tester.pumpWidget(HomeworkScannerApp(controller: controller));
    // The grid has no indeterminate animation once all pages are done. Pump
    // explicit frames so a regression fails an assertion rather than hanging
    // in pumpAndSettle's ten-minute window.
    await pumpFrames(tester);
    if (openDocument && controller.document != null) {
      final card = find.byKey(Key('document-${controller.document!.id}'));
      expect(card, findsOneWidget);
      await tester.tap(card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
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
    expect(find.text('裁切候选'), findsOneWidget);
    expect(find.text('检测框'), findsOneWidget);
    expect(find.text('整图 2%'), findsWidgets);
    expect(find.byKey(const Key('shadow-flatten-switch')), findsOneWidget);
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

  testWidgets('文档库显示多个文档并可新建第二份', (tester) async {
    await addPages(tester, 1);
    final second = await store.createDocument(title: '第二份作业');
    final firstId = controller.document!.id;

    await pumpApp(tester, openDocument: false);
    expect(find.text('我的扫描'), findsOneWidget);
    expect(find.byKey(Key('document-$firstId')), findsOneWidget);
    expect(find.byKey(Key('document-${second.id}')), findsOneWidget);
    expect(find.text('第二份作业'), findsOneWidget);

    expect(find.byKey(const Key('scan-new-document')), findsOneWidget);
    final third = await tester.runAsync(() async {
      final document = await store.createDocument(title: '第三份');
      await controller.openDocument(document.id);
      return document;
    });
    await pumpFrames(tester);
    expect(controller.document!.id, third!.id);
    expect(controller.document!.id, isNot(firstId));
    expect(controller.document!.id, isNot(second.id));
    expect(controller.document!.pages, isEmpty);
  });

  testWidgets('设置页可修改默认色彩和默认裁切', (tester) async {
    await pumpApp(tester, openDocument: false);
    await tester.tap(find.byKey(const Key('settings-action')));
    await pumpFrames(tester);
    expect(find.text('扫描设置'), findsOneWidget);
    expect(controller.settings.defaultColorMode, ScanColorMode.grayscale);
    expect(controller.settings.defaultCropMode, DefaultCropMode.auto);

    await tester.tap(find.byKey(const Key('settings-color-COLOR')));
    await pumpFrames(tester);
    expect(controller.settings.defaultColorMode, ScanColorMode.color);

    await tester.tap(find.byKey(const Key('settings-crop-detector')));
    await pumpFrames(tester);
    expect(controller.settings.defaultCropMode, DefaultCropMode.detector);
  });

  testWidgets('导出对话框带默认文件名并可关闭适配 A4', (tester) async {
    await addPages(tester, 2);
    await pumpApp(tester);

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

  testWidgets('设置页把修改交给注入的 SettingsStore', (tester) async {
    final recordingStore = RecordingSettingsStore(root: temp);
    controller.dispose();
    controller = DocumentController(
      engine: engine,
      store: store,
      exporter: exporter,
      initialSettings: const ScanSettings(
        defaultColorMode: ScanColorMode.grayscale,
        defaultCropMode: DefaultCropMode.auto,
      ),
      settingsStore: recordingStore,
    );

    await pumpApp(tester, openDocument: false);
    await tester.tap(find.byKey(const Key('settings-action')));
    await pumpFrames(tester);

    await tester.tap(find.byKey(const Key('settings-color-BLACK_AND_WHITE')));
    await pumpFrames(tester);
    expect(
      recordingStore.saved?.defaultColorMode,
      ScanColorMode.blackAndWhite,
    );

    await tester.tap(find.byKey(const Key('settings-crop-detector')));
    await pumpFrames(tester);
    expect(
      recordingStore.saved?.defaultColorMode,
      ScanColorMode.blackAndWhite,
    );
    expect(
      recordingStore.saved?.defaultCropMode,
      DefaultCropMode.detector,
    );
    // 两次修改各写一次，没有多余的保存。
    expect(recordingStore.saves, hasLength(2));
  });

  testWidgets('空文档库展示空状态和扫描第一份文档入口', (tester) async {
    // 同步建目录：testWidgets 的 fake async 里 await 真实文件 I/O 会卡住。
    // 目录建在 setUp 的临时目录下，由 tearDown 统一清理。
    final emptyRoot = Directory(
      '${temp.path}/empty_library',
    )..createSync(recursive: true);
    controller.dispose();
    controller = DocumentController(
      engine: engine,
      store: SyncSessionStore(root: emptyRoot),
      exporter: exporter,
    );
    // 刻意不调用 initialize()：真实启动会自动创建第一份文档，
    // 这里要验证的正是“一份文档都没有”的空状态。

    await pumpApp(tester, openDocument: false);

    expect(find.text('我的扫描'), findsOneWidget);
    expect(find.text('还没有扫描文档'), findsOneWidget);
    expect(find.text('扫描第一份文档'), findsOneWidget);
    expect(find.byKey(const Key('empty-new-document')), findsOneWidget);
    expect(find.byKey(const Key('scan-new-document')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('document-'),
      ),
      findsNothing,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('处理中的页面禁用保存图片，完成后可保存处理后路径', (tester) async {
    const channel = MethodChannel('homework_scanner/gallery');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        calls.add(call);
        return <String, Object?>{
          'ok': true,
          'savedPath': 'Pictures/作业扫描/ok.jpg',
        };
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    // 先在队列空闲时打开文档：openDocument 会 waitForIdle()，而引擎如果此时被
    // pauseScans 挂起，导航就永远不会完成。所以先打开文档，再暂停引擎加页。
    await addPages(tester, 1);
    await pumpApp(tester);

    engine.pauseScans();
    final page = await tester.runAsync(
      () => controller.addCapturedPage(fixtureJpegPath()),
    );
    await pumpFrames(tester);

    await tester.tap(find.byKey(Key('page-tile-${page!.id}')));
    await pumpFrames(tester);

    // 还在引擎里，没有处理结果，保存必须是禁用的。
    expect(
      controller.pageById(page.id)!.status,
      PageStatus.processing,
    );
    final during = tester.widget<IconButton>(
      find.byKey(const Key('save-image-button')),
    );
    expect(during.onPressed, isNull);

    engine.resumeScans();
    await tester.runAsync(() => controller.waitForIdle());
    await pumpFrames(tester);

    final done = controller.pageById(page.id)!;
    expect(done.isDone, isTrue);
    final after = tester.widget<IconButton>(
      find.byKey(const Key('save-image-button')),
    );
    expect(after.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('save-image-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(calls, hasLength(1));
    expect(calls.single.method, 'saveImage');
    final args = calls.single.arguments! as Map<Object?, Object?>;
    // 只允许把处理结果交给原生，原图不能进相册。
    expect(args['path'], done.processedPath);
    expect(args['path'], isNot(done.originalPath));
    expect(args['path'], endsWith('.jpg'));
    expect(args['fileName'], endsWith('.jpg'));
    expect(args['fileName'].toString(), isNot(contains('/')));
    expect(find.textContaining('已保存到相册'), findsOneWidget);
  });

  testWidgets('处理失败的页面禁用保存图片', (tester) async {
    engine.failScansRemaining = 1;
    final page = await tester.runAsync(() async {
      final added = await controller.addCapturedPage(fixtureJpegPath());
      await controller.waitForIdle();
      return added;
    });
    await pumpApp(tester);
    await tester.tap(find.byKey(Key('page-tile-${page!.id}')));
    await pumpFrames(tester);

    final failed = controller.pageById(page.id)!;
    expect(failed.status, PageStatus.failed);
    expect(failed.processedPath, isNull);
    final button = tester.widget<IconButton>(
      find.byKey(const Key('save-image-button')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('处理失败，原图未修改'), findsOneWidget);
  });

  testWidgets('重处理失败的页面禁用保存图片，不把上一次结果当本次输出', (tester) async {
    final added = (await addPages(tester, 1)).single;
    // addPages 返回的是入队时的页面快照，完成状态要从 controller 现取。
    final page = controller.pageById(added.id)!;
    final stalePath = page.processedPath;
    expect(page.isDone, isTrue);
    expect(stalePath, isNotNull);

    // 已完成页切换色彩会重新入队；让这一轮处理失败。失败路径保留旧结果
    // （页面仍把它显示在原图上），但那份图属于旧设置，不能再写入相册。
    engine.failScansRemaining = 1;
    await tester.runAsync(() async {
      await controller.setColorMode(page.id, ScanColorMode.color);
      await controller.waitForIdle();
    });

    final failed = controller.pageById(page.id)!;
    expect(failed.status, PageStatus.failed);
    expect(failed.isDone, isFalse);
    expect(failed.processedPath, stalePath);

    await pumpApp(tester);
    await tester.tap(find.byKey(Key('page-tile-${page.id}')));
    await pumpFrames(tester);

    expect(find.text('处理失败，原图未修改'), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.byKey(const Key('save-image-button')),
    );
    expect(button.onPressed, isNull);
  });
}

/// Test-only settings store: records the last written [ScanSettings] without
/// touching the disk, so the widget test can assert the settings page reaches
/// the persistence layer without mixing real file I/O into fake async.
class RecordingSettingsStore extends SettingsStore {
  RecordingSettingsStore({required super.root});

  final List<ScanSettings> saves = <ScanSettings>[];

  ScanSettings? get saved => saves.isEmpty ? null : saves.last;

  @override
  Future<void> save(ScanSettings settings) async {
    saves.add(settings);
  }
}
