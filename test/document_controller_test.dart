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

  test('addCapturedPages 一次导入多张并按选择顺序入队', () async {
    final pages = await controller.addCapturedPages([
      fixtureJpegPath(),
      fixtureJpegPath(),
      fixtureJpegPath(),
    ]);
    await controller.waitForIdle();

    expect(pages, hasLength(3));
    expect(controller.document!.pages.map((page) => page.id), [
      for (final page in pages) page.id,
    ]);
    expect(controller.document!.pages.every((page) => page.isDone), isTrue);
    expect(engine.scanCount, 3);
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

  test('摊开笔记本：检测框只保留部分纸面时自动改用纸面外框', () async {
    engine.detection = DetectResult(
      quad: const [(0.3, 0.1), (0.7, 0.1), (0.7, 0.9), (0.3, 0.9)],
      score: 0.6,
      meanProb: 0.94,
      coverage: 0.52,
      frameFill: 0.32,
      detectionStage: 'capture',
      sourceWidth: 900,
      sourceHeight: 1200,
      segmentationMs: 40,
      detectionMs: 5,
      candidates: const [
        QuadCandidate(
          source: 'capture',
          quad: [(0.3, 0.1), (0.7, 0.1), (0.7, 0.9), (0.3, 0.9)],
          score: 0.6,
          meanProb: 0.94,
          coverage: 0.52,
          frameFill: 0.32,
        ),
        QuadCandidate(
          source: 'paper_outer',
          quad: [(0.04, 0.06), (0.96, 0.06), (0.96, 0.94), (0.04, 0.94)],
          score: 0.72,
          meanProb: 0.82,
          coverage: 0.99,
          frameFill: 0.84,
        ),
        QuadCandidate(
          source: 'default',
          quad: [(0.02, 0.02), (0.98, 0.02), (0.98, 0.98), (0.02, 0.98)],
          score: 0.5,
          meanProb: 0.7,
          coverage: 1,
          frameFill: 0.92,
        ),
      ],
    );

    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();

    final done = controller.pageById(page.id)!;
    expect(done.quadSource, QuadSource.paperOuter);
    expect(done.needsReview, isTrue);
    expect(done.candidates, hasLength(3));
    expect(engine.lastOptions?.quad, const [
      (0.04, 0.06),
      (0.96, 0.06),
      (0.96, 0.94),
      (0.04, 0.94),
    ]);
  });

  test('手动切换候选框会重新处理并保留候选列表', () async {
    engine.detection = DetectResult(
      quad: const [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)],
      score: 0.96,
      meanProb: 0.97,
      coverage: 1,
      frameFill: 0.8,
      detectionStage: 'capture',
      sourceWidth: 900,
      sourceHeight: 1200,
      segmentationMs: 40,
      detectionMs: 5,
      candidates: const [
        QuadCandidate(
          source: 'capture',
          quad: [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)],
          score: 0.96,
          meanProb: 0.97,
          coverage: 1,
          frameFill: 0.8,
        ),
        QuadCandidate(
          source: 'paper_outer',
          quad: [(0.02, 0.02), (0.98, 0.02), (0.98, 0.98), (0.02, 0.98)],
          score: 0.7,
          meanProb: 0.75,
          coverage: 1,
          frameFill: 0.92,
        ),
        QuadCandidate(
          source: 'default',
          quad: [(0.02, 0.02), (0.98, 0.02), (0.98, 0.98), (0.02, 0.98)],
          score: 0.7,
          meanProb: 0.75,
          coverage: 1,
          frameFill: 0.92,
        ),
      ],
    );

    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();
    final outer = controller
        .pageById(page.id)!
        .candidates
        .firstWhere((candidate) => candidate.source == 'paper_outer');
    await controller.applyCandidate(page.id, outer);
    await controller.waitForIdle();

    final done = controller.pageById(page.id)!;
    expect(done.quadSource, QuadSource.paperOuter);
    expect(done.needsReview, isTrue);
    expect(done.candidates, hasLength(3));
    expect(engine.lastOptions?.quad, outer.quad);
  });

  test('手动四角重处理生成新结果路径并删除旧图', () async {
    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();
    final before = controller.pageById(page.id)!;
    final oldPath = before.processedPath!;

    const manualQuad = <NormalizedPoint>[
      (0.1, 0.1),
      (0.9, 0.1),
      (0.9, 0.9),
      (0.1, 0.9),
    ];
    await controller.setManualQuad(page.id, manualQuad);
    await controller.waitForIdle();

    final after = controller.pageById(page.id)!;
    expect(after.quadSource, QuadSource.manual);
    expect(after.quad, manualQuad);
    expect(after.processedPath, isNot(oldPath));
    expect(File(oldPath).existsSync(), isFalse);
    expect(engine.lastOptions?.quad, manualQuad);
  });

  test('检测框只占画面 28% 时即使内容覆盖高也不采用', () async {
    engine.detection = DetectResult(
      quad: const [(0.29, 0.06), (0.97, 0.01), (1.0, 0.43), (0.32, 0.48)],
      score: 0.29,
      meanProb: 0.51,
      coverage: 0.996,
      frameFill: 0.286,
      detectionStage: 'capture',
      sourceWidth: 900,
      sourceHeight: 1200,
      segmentationMs: 40,
      detectionMs: 5,
      candidates: const [
        QuadCandidate(
          source: 'capture',
          quad: [(0.29, 0.06), (0.97, 0.01), (1.0, 0.43), (0.32, 0.48)],
          score: 0.29,
          meanProb: 0.51,
          coverage: 0.996,
          frameFill: 0.286,
        ),
        QuadCandidate(
          source: 'default',
          quad: [(0.02, 0.02), (0.98, 0.02), (0.98, 0.98), (0.02, 0.98)],
          score: 0.16,
          meanProb: 0.16,
          coverage: 1,
          frameFill: 0.9216,
        ),
      ],
    );

    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();

    final done = controller.pageById(page.id)!;
    expect(done.quadSource, QuadSource.fallback);
    expect(done.needsReview, isTrue);
    expect(engine.lastOptions?.quad, kDefaultInsetQuad);
  });

  test('去阴影开关会传入原生 scan，并可关闭', () async {
    final page = await controller.addCapturedPage(fixtureJpegPath());
    await controller.waitForIdle();
    expect(controller.pageById(page.id)!.shadowFlatten, isTrue);
    expect(engine.lastOptions?.shadowFlatten, isTrue);

    await controller.setShadowFlatten(page.id, false);
    await controller.waitForIdle();

    expect(controller.pageById(page.id)!.shadowFlatten, isFalse);
    expect(engine.lastOptions?.shadowFlatten, isFalse);
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
    final before = controller.pageById(page.id)!;
    final firstQuad = before.quad;
    final firstPath = before.processedPath!;
    final firstScanCount = engine.scanCount;

    await controller.setColorMode(page.id, ScanColorMode.blackAndWhite);
    await controller.waitForIdle();

    final updated = controller.pageById(page.id)!;
    expect(updated.colorMode, ScanColorMode.blackAndWhite);
    expect(updated.quad, firstQuad);
    expect(updated.processedPath, isNot(firstPath));
    expect(File(firstPath).existsSync(), isFalse);
    expect(File(updated.processedPath!).existsSync(), isTrue);
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

  test('openDocument 可切换到另一份文档', () async {
    final firstId = controller.document!.id;
    final second = await store.createDocument(title: '第二份');
    await controller.openDocument(second.id);

    expect(controller.document!.id, second.id);
    expect(controller.document!.title, '第二份');
    expect(controller.document!.id, isNot(firstId));
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
