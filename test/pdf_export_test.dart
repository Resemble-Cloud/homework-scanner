import 'dart:convert';
import 'dart:io';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homework_scanner/models/scan_document.dart';
import 'package:homework_scanner/services/pdf_export_service.dart';

import 'support/fakes.dart';

void main() {
  late Directory temp;
  late List<int> jpegBytes;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('scanner_pdf_test_');
    jpegBytes = await File(fixtureJpegPath()).readAsBytes();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  ScanPage makePage(int index) {
    final path = '${temp.path}/page_$index.jpg';
    File(path).writeAsBytesSync(jpegBytes);
    return ScanPage(
      id: 'page_$index',
      originalPath: path,
      processedPath: path,
      colorMode: ScanColorMode.grayscale,
      status: PageStatus.done,
      quadSource: QuadSource.capture,
      createdAt: DateTime.utc(2026, 10, 24),
      outputWidth: 900,
      outputHeight: 1200,
      fileBytes: jpegBytes.length,
    );
  }

  ScanDocument makeDocument(int count) {
    final now = DateTime.utc(2026, 10, 24);
    return ScanDocument(
      id: 'doc_pdf',
      title: '扫描测试',
      createdAt: now,
      updatedAt: now,
      pages: [for (var i = 0; i < count; i++) makePage(i)],
    );
  }

  test('20 页顺序组装，JPEG 原字节直接嵌入且页数正确', () async {
    final document = makeDocument(20);
    final output = '${temp.path}/out/扫描_20页.pdf';
    final result = await PdfExportService().export(
      document,
      outputPath: output,
      fitA4: true,
    );

    expect(result.pageCount, 20);
    expect(result.pageSizesPt, hasLength(20));
    expect(result.pageSizesPt.every((size) => size.$1 < size.$2), isTrue);
    final bytes = await File(output).readAsBytes();
    expect(ascii.decode(bytes.sublist(0, 4)), '%PDF');
    final text = latin1.decode(bytes, allowInvalid: true);
    final pages = RegExp(r'/Type\s*/Page\b').allMatches(text).length;
    expect(pages, 20);
    // Each page is a DCTDecode stream, i.e. the original JPEG bytes rather than
    // a Flate-compressed RGB bitmap.
    expect(
      RegExp(r'/DCTDecode').allMatches(text).length,
      greaterThanOrEqualTo(20),
    );
    expect(_contains(bytes, jpegBytes), isTrue);

    // A4 portrait page size is 595 x 842 pt.
    expect(result.pageSizesPt.first.$1, closeTo(595.28, 0.1));
    expect(result.pageSizesPt.first.$2, closeTo(841.89, 0.1));
  });

  test('关闭适配 A4 时页面尺寸跟随图片宽高比', () async {
    final document = makeDocument(2);
    final output = '${temp.path}/out/ratio.pdf';
    final result = await PdfExportService().export(
      document,
      outputPath: output,
      fitA4: false,
    );

    // Fixture is 900x1200 portrait; long edge is 842 pt.
    expect(result.pageSizesPt.first.$2, closeTo(842, 0.01));
    expect(result.pageSizesPt.first.$1, closeTo(842 * 900 / 1200, 0.01));
  });

  test('未完成/缺失文件在写出 PDF 前拒绝', () async {
    final document = makeDocument(2);
    final pending = document.copyWith(
      pages: [
        document.pages.first,
        document.pages.last.copyWith(status: PageStatus.processing),
      ],
    );
    await expectLater(
      PdfExportService().export(
        pending,
        outputPath: '${temp.path}/bad.pdf',
        fitA4: true,
      ),
      throwsA(isA<PdfExportException>()),
    );
    expect(File('${temp.path}/bad.pdf').existsSync(), isFalse);
  });

  test('空文档拒绝导出', () async {
    final now = DateTime.utc(2026);
    await expectLater(
      PdfExportService().export(
        ScanDocument(
          id: 'empty',
          title: 'empty',
          createdAt: now,
          updatedAt: now,
          pages: const [],
        ),
        outputPath: '${temp.path}/empty.pdf',
        fitA4: true,
      ),
      throwsA(isA<PdfExportException>()),
    );
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
