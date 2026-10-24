import 'dart:io';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homework_scanner/models/scan_document.dart';
import 'package:homework_scanner/services/document_controller.dart';
import 'package:homework_scanner/services/pdf_export_service.dart';
import 'package:homework_scanner/services/session_store.dart';

import 'support/fakes.dart';

void main() {
  late Directory temp;
  late SessionStore store;
  late FakeScanEngine engine;
  late RecordingPdfExporter exporter;
  late DocumentController controller;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('scanner_ctrl_test_');
    store = SessionStore(root: temp);
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
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('连续入队并按顺序串行处理，每次只跑一个原生扫描', () async {
    engine = FakeScanEngine(
      fixturePath: fixtureJpegPath(),
      outputDir: Directory('${temp.path}/native'),
      processingDelay: const Duration(milliseconds: 15),
    );
    controller.dispose();
    controller = DocumentController(
      engine: engine,
      store: store,
      exporter: exporter,
    );
    await controller.initialize();

    final added = await Future.wait([
      for (var i = 0; i < 4; i++) controller.addCapturedPage(fixtureJpegPath()),
    ]);
    await controller.waitForIdle();

    final document = controller.document!;
    expect(document.pages.map((p) => p.id), added.map((p) => p.id));
    expect(document.pages.every((p) => p.isDone), isTrue);
    expect(engine.scanCount, 4);
    expect(engine.maxActiveScans, 1);
    for (final page in document.pages) {
      expect(File(page.originalPath).existsSync(), isTrue);
      expect(File(page.processedPath!).existsSync(), isTrue);
      expect(page.quadSource, QuadSource.capture);
      expect(page.needsReview, isFalse);
    }
  });

  test('低置信度/取景占比过小时使用整图内缩 2% 并标记建议检查', () async {
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

    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();

    final done = controller.pageById(page.id)!;
    expect(done.status, PageStatus.done);
    expect(done.quadSource, QuadSource.fallback);
    expect(done.needsReview, isTrue);
    expect(done.reviewReason, contains('22%'));
    expect(engine.lastOptions?.quad, kDefaultInsetQuad);
  });

  test('处理失败保留原图，重试后成功且不覆盖原图', () async {
    engine.failScansRemaining = 1;
    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();

    final failed = controller.pageById(page.id)!;
    expect(failed.status, PageStatus.failed);
    expect(failed.errorCode, 'FAKE_FAIL');
    final originalBytes = await File(failed.originalPath).readAsBytes();
    expect(originalBytes, isNotEmpty);

    await controller.retryPage(page.id);
    await controller.waitForIdle();

    final recovered = controller.pageById(page.id)!;
    expect(recovered.status, PageStatus.done);
    expect(recovered.errorCode, isNull);
    expect(await File(recovered.originalPath).readAsBytes(), originalBytes);
  });

  test('切换色彩模式会保留四角并只重新入队该页', () async {
    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();
    final firstQuad = controller.pageById(page.id)!.quad;
    final firstScanCount = engine.scanCount;

    await controller.setColorMode(page.id, ScanColorMode.blackAndWhite);
    await controller.waitForIdle();

    final updated = controller.pageById(page.id)!;
    expect(updated.colorMode, ScanColorMode.blackAndWhite);
    expect(updated.quad, firstQuad);
    expect(engine.scanCount, firstScanCount + 1);
    expect(engine.lastOptions?.colorMode, ScanColorMode.blackAndWhite);
    expect(engine.detectCount, 1, reason: '重处理应复用四角，不重复检测');
  });

  test('长按排序后的顺序落盘，导出时按新顺序调用', () async {
    final first = await controller.addCapturedPage(fixtureJpegPath());
    final second = await controller.addCapturedPage(fixtureJpegPath());
    final third = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();

    await controller.movePage(0, 2);
    expect(controller.document!.pages.map((p) => p.id), [
      second.id,
      third.id,
      first.id,
    ]);

    final restored = await store.loadById(controller.document!.id);
    expect(restored!.pages.map((p) => p.id), [second.id, third.id, first.id]);

    final result = await controller.exportPdf(fileName: '作业/测试', fitA4: false);
    expect(exporter.calls, 1);
    expect(exporter.pageIds, [second.id, third.id, first.id]);
    expect(exporter.fitA4, isFalse);
    expect(result.path, endsWith('作业_测试.pdf'));
    expect(controller.document!.exportedAt, isNotNull);
  });

  test('未导出会话可由新控制器恢复', () async {
    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();
    final documentId = controller.document!.id;
    controller.dispose();

    final second = DocumentController(
      engine: FakeScanEngine(
        fixturePath: fixtureJpegPath(),
        outputDir: Directory('${temp.path}/native2'),
      ),
      store: store,
      exporter: exporter,
    );
    await second.initialize();
    expect(second.document!.id, documentId);
    expect(second.document!.pages.single.id, page.id);
    expect(second.document!.pages.single.isDone, isTrue);
    second.dispose();
  });

  test('已导出的会话冷启动不会重新打开，避免误以为还有未导出内容', () async {
    await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();
    await controller.exportPdf(fileName: 'first', fitA4: true);
    final exportedId = controller.document!.id;
    controller.dispose();

    final second = DocumentController(
      engine: FakeScanEngine(
        fixturePath: fixtureJpegPath(),
        outputDir: Directory('${temp.path}/native3'),
      ),
      store: store,
      exporter: exporter,
    );
    await second.initialize();
    expect(second.document!.id, isNot(exportedId));
    expect(second.document!.pages, isEmpty);
    second.dispose();
  });

  test('页面存在未完成时拒绝导出', () async {
    engine.failScansRemaining = 1;
    await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();
    await expectLater(
      controller.exportPdf(fileName: 'bad', fitA4: true),
      throwsA(isA<PdfExportException>()),
    );
    expect(exporter.calls, 0);
  });

  test('恢复时把中断的 processing 状态重新排队', () async {
    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();
    final document = controller.document!;
    final interrupted = document.pages.single.copyWith(
      status: PageStatus.processing,
      clearProcessed: true,
    );
    await store.save(document.replacePage(interrupted));
    controller.dispose();

    final second = DocumentController(
      engine: FakeScanEngine(
        fixturePath: fixtureJpegPath(),
        outputDir: Directory('${temp.path}/native4'),
      ),
      store: store,
      exporter: exporter,
    );
    await second.initialize();
    await second.waitForIdle();
    expect(second.pageById(page.id)?.status, PageStatus.done);
    second.dispose();
  });
}
