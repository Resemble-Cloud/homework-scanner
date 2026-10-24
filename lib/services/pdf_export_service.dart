import 'dart:io';
import 'dart:math' as math;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/scan_document.dart';

class PdfExportException implements Exception {
  const PdfExportException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'PdfExportException($code): $message';
}

class PdfExportProgress {
  const PdfExportProgress({
    required this.donePages,
    required this.totalPages,
    required this.currentLabel,
  });

  final int donePages;
  final int totalPages;
  final String currentLabel;

  double get fraction => totalPages == 0 ? 0 : donePages / totalPages;
}

class PdfExportResult {
  const PdfExportResult({
    required this.path,
    required this.bytes,
    required this.pageCount,
    required this.pageSizesPt,
    required this.elapsed,
  });

  final String path;
  final int bytes;
  final int pageCount;

  /// Page dimensions in PDF points, in document order.
  final List<(double, double)> pageSizesPt;
  final Duration elapsed;

  String get sizeLabel => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} KB';
}

typedef PdfProgressCallback = void Function(PdfExportProgress progress);

/// Assembles already-processed page images into a PDF.
///
/// JPEGs are handed to the PDF writer as their original bytes (DCTDecode), so
/// there is no decode/resize/encode round trip. Pages are read and added one at
/// a time; the document graph holds compressed streams, not N decoded 12 MP
/// bitmaps. This is the memory invariant exercised by the 20-page test.
abstract interface class PdfExporter {
  Future<PdfExportResult> export(
    ScanDocument document, {
    required String outputPath,
    required bool fitA4,
    PdfProgressCallback? onProgress,
  });
}

class PdfExportService implements PdfExporter {
  const PdfExportService();

  static const double _a4Short = 21.0 * PdfPageFormat.cm;
  static const double _a4Long = 29.7 * PdfPageFormat.cm;
  static const double _longEdge = 842; // A4 long edge in points.

  @override
  Future<PdfExportResult> export(
    ScanDocument document, {
    required String outputPath,
    required bool fitA4,
    PdfProgressCallback? onProgress,
  }) async {
    final pages = document.pages;
    if (pages.isEmpty) {
      throw const PdfExportException('NO_PAGES', '文档还没有页面');
    }
    for (final page in pages) {
      final path = page.processedPath;
      if (page.status != PageStatus.done || path == null) {
        throw PdfExportException(
          'PAGE_NOT_READY',
          '第 ${document.pageNumber(page.id)} 页尚未处理完成',
        );
      }
      if (!await File(path).exists()) {
        throw PdfExportException(
          'PAGE_FILE_MISSING',
          '第 ${document.pageNumber(page.id)} 页的处理结果不存在',
        );
      }
    }

    final started = DateTime.now();
    final pdf = pw.Document(
      title: document.title,
      author: '作业扫描',
      creator: 'homework_scanner',
    );
    final pageSizes = <(double, double)>[];

    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      onProgress?.call(
        PdfExportProgress(
          donePages: index,
          totalPages: pages.length,
          currentLabel: '第 ${index + 1} 页',
        ),
      );
      final bytes = await File(page.processedPath!).readAsBytes();
      // MemoryImage reads only the JPEG header for dimensions, and
      // PdfImage.file later embeds the same bytes with /DCTDecode. No pixels
      // are decoded or re-encoded here.
      final image = pw.MemoryImage(bytes);
      if (image.width == null || image.height == null) {
        throw PdfExportException(
          'PAGE_IMAGE_INVALID',
          '第 ${index + 1} 页图片无法读取尺寸',
        );
      }
      final imageWidth = image.width!.toDouble();
      final imageHeight = image.height!.toDouble();
      final isLandscape = imageWidth > imageHeight;
      final format = fitA4
          ? PdfPageFormat(
              isLandscape ? _a4Long : _a4Short,
              isLandscape ? _a4Short : _a4Long,
            )
          : PdfPageFormat(
              isLandscape ? _longEdge : _longEdge * imageWidth / imageHeight,
              isLandscape ? _longEdge * imageHeight / imageWidth : _longEdge,
            );
      final margin = fitA4 ? 18.0 : 12.0;
      final availableWidth = format.width - margin * 2;
      final availableHeight = format.height - margin * 2;
      final scale = math.min(
        availableWidth / imageWidth,
        availableHeight / imageHeight,
      );
      final drawWidth = imageWidth * scale;
      final drawHeight = imageHeight * scale;

      pdf.addPage(
        pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.all(margin),
          build: (context) => pw.Center(
            child: pw.Image(
              image,
              width: drawWidth,
              height: drawHeight,
              fit: pw.BoxFit.contain,
            ),
          ),
        ),
      );
      pageSizes.add((format.width, format.height));
    }

    onProgress?.call(
      PdfExportProgress(
        donePages: pages.length,
        totalPages: pages.length,
        currentLabel: '写入 PDF',
      ),
    );

    final out = File(outputPath);
    await out.parent.create(recursive: true);
    final data = await pdf.save();
    await out.writeAsBytes(data, flush: true);
    return PdfExportResult(
      path: out.path,
      bytes: data.length,
      pageCount: pages.length,
      pageSizesPt: pageSizes,
      elapsed: DateTime.now().difference(started),
    );
  }
}
