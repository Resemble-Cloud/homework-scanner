import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homework_scanner/models/scan_document.dart';
import 'package:homework_scanner/services/session_store.dart';

void main() {
  group('ScanPage JSON', () {
    test('保留原图、四角、色彩模式、处理结果和状态', () {
      final created = DateTime.utc(2026, 10, 24, 12, 30);
      final page = ScanPage(
        id: 'page_1',
        originalPath: '/app/originals/page_1.jpg',
        processedPath: '/app/processed/page_1.jpg',
        colorMode: ScanColorMode.grayscale,
        status: PageStatus.done,
        quad: const [(0.02, 0.02), (0.98, 0.02), (0.98, 0.98), (0.02, 0.98)],
        quadSource: QuadSource.manual,
        needsReview: true,
        reviewReason: '测试',
        detectionScore: 0.42,
        detectionFrameFill: 0.22,
        detectionCoverage: 0.9,
        engineStage: 'capture',
        candidates: const [
          QuadCandidate(
            source: 'paper_outer',
            quad: [(0.02, 0.02), (0.98, 0.02), (0.98, 0.98), (0.02, 0.98)],
            score: 0.72,
            meanProb: 0.82,
            coverage: 0.99,
            frameFill: 0.84,
          ),
        ],
        createdAt: created,
        processingMs: 3200,
        engineMs: 2100,
        outputWidth: 1773,
        outputHeight: 2254,
        fileBytes: 364000,
      );

      final restored = ScanPage.fromJson(
        Map<String, dynamic>.from(page.toJson()),
      );
      expect(restored.id, page.id);
      expect(restored.originalPath, page.originalPath);
      expect(restored.processedPath, page.processedPath);
      expect(restored.colorMode, ScanColorMode.grayscale);
      expect(restored.status, PageStatus.done);
      expect(restored.quad, page.quad);
      expect(restored.quadSource, QuadSource.manual);
      expect(restored.needsReview, isTrue);
      expect(restored.detectionScore, 0.42);
      expect(restored.engineMs, 2100);
      expect(restored.candidates, hasLength(1));
      expect(restored.candidates.single.source, 'paper_outer');
      expect(restored.candidates.single.coverage, 0.99);
      expect(restored.candidates.single.background, closeTo(0.18, 1e-9));
      expect(restored.createdAt, created);
    });

    test('Sprint 1/2 旧 JSON 迁移：缺省 candidates 与 shadowFlatten 使用安全默认', () {
      final restored = ScanPage.fromJson(<String, dynamic>{
        'id': 'legacy',
        'originalPath': '/tmp/legacy.jpg',
        'colorMode': 'AUTO',
        'status': 'done',
        'quadSource': 'capture',
        'needsReview': false,
        'createdAt': '2026-10-24T12:00:00.000Z',
      });
      expect(restored.candidates, isEmpty);
      expect(restored.shadowFlatten, isTrue);
      expect(restored.quadSource, QuadSource.capture);
    });
  });

  group('ScanDocument ordering', () {
    ScanPage page(String id) => ScanPage(
      id: id,
      originalPath: '/tmp/$id.jpg',
      colorMode: ScanColorMode.auto,
      status: PageStatus.done,
      createdAt: DateTime.utc(2026),
    );

    ScanDocument document(List<String> ids) => ScanDocument(
      id: 'doc',
      title: '测试',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      pages: ids.map(page).toList(),
    );

    test('movePage 把页面移动到最终索引，并清除已导出标记', () {
      final original = document(['a', 'b', 'c', 'd'])
          .copyWith(exportedAt: DateTime.utc(2026));
      final moved = original.movePage(0, 2);
      expect(moved.pages.map((p) => p.id), ['b', 'c', 'a', 'd']);
      expect(moved.exportedAt, isNull);
    });

    test('越界排序是 no-op', () {
      final original = document(['a', 'b']);
      expect(original.movePage(-1, 1).pages.map((p) => p.id), ['a', 'b']);
      expect(original.movePage(0, 9).pages.map((p) => p.id), ['a', 'b']);
    });

    test('删除页面保持其余顺序', () {
      final updated = document(['a', 'b', 'c']).removePage('b');
      expect(updated.pages.map((p) => p.id), ['a', 'c']);
    });
  });

  test('默认兜底四角是整图内缩 2%', () {
    expect(kDefaultInsetQuad, const <NormalizedPoint>[
      (0.02, 0.02),
      (0.98, 0.02),
      (0.98, 0.98),
      (0.02, 0.98),
    ]);
  });

  group('PDF 文件名', () {
    test('默认名称包含日期时间', () {
      expect(
        defaultPdfFileName(DateTime(2026, 10, 24, 15, 3, 4)),
        '扫描_20261024_150304.pdf',
      );
    });

    test('过滤非法字符并补全扩展名', () {
      expect(normalizePdfFileName('作业/一:二'), '作业_一_二.pdf');
      expect(normalizePdfFileName('我的作业.pdf'), '我的作业.pdf');
      expect(normalizePdfFileName('   '), startsWith('扫描_'));
    });
  });
}
