import 'dart:convert';
import 'dart:io';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:homework_scanner/models/scan_document.dart';
import 'package:homework_scanner/services/pdf_export_service.dart';
import 'package:homework_scanner/services/session_store.dart';
import 'package:path/path.dart' as p;

const fakeTimings = ScanStageTimings(
  decodeMs: 30,
  segmentationMs: 40,
  detectionMs: 5,
  colorModeMs: 2,
  extractMs: 60,
  encodeMs: 8,
  totalMs: 145,
);

DetectResult goodDetection({String stage = 'capture'}) => DetectResult(
  quad: const [(0.08, 0.06), (0.92, 0.07), (0.93, 0.94), (0.07, 0.93)],
  score: 0.96,
  meanProb: 0.98,
  coverage: 0.99,
  frameFill: 0.82,
  detectionStage: stage,
  sourceWidth: 900,
  sourceHeight: 1200,
  segmentationMs: 40,
  detectionMs: 5,
);

class FakeScanEngine implements ScanEngine {
  FakeScanEngine({
    required this.fixturePath,
    required this.outputDir,
    DetectResult? detection,
    this.processingDelay = Duration.zero,
  }) : detection = detection ?? goodDetection() {
    outputDir.createSync(recursive: true);
  }

  final String fixturePath;
  final Directory outputDir;
  final Duration processingDelay;
  DetectResult detection;

  int failScansRemaining = 0;
  int detectCount = 0;
  int scanCount = 0;
  int initializeCount = 0;
  int activeScans = 0;
  int maxActiveScans = 0;
  final List<ScanOptions> scanOptions = <ScanOptions>[];
  ScanOptions? lastOptions;

  @override
  Future<EngineInfo> engineInfo() async => const EngineInfo(
    modelAsset: 'fake-model.tflite',
    opencvVersion: 'fake',
    initialized: true,
  );

  @override
  Future<void> initialize() async {
    initializeCount++;
  }

  @override
  Future<DetectResult> detectDocument(String sourcePath) async {
    detectCount++;
    return detection;
  }

  @override
  Future<CropResult> cropImage(
    String sourcePath,
    List<NormalizedPoint> quad, {
    ScanOptions options = const ScanOptions(),
  }) async {
    final result = await scan(
      sourcePath,
      options: ScanOptions(
        colorMode: options.colorMode,
        maxPixels: options.maxPixels,
        quad: quad,
      ),
    );
    return CropResult(
      outputPath: result.outputPath,
      outputFormat: result.outputFormat,
      outputWidth: result.outputWidth,
      outputHeight: result.outputHeight,
      fileBytes: result.fileBytes,
      colorMode: result.colorMode,
      timings: result.timings,
    );
  }

  @override
  Future<ScanResult> scan(
    String sourcePath, {
    ScanOptions options = const ScanOptions(),
  }) async {
    scanCount++;
    activeScans++;
    maxActiveScans = activeScans > maxActiveScans
        ? activeScans
        : maxActiveScans;
    lastOptions = options;
    scanOptions.add(options);
    try {
      if (processingDelay > Duration.zero) {
        await Future<void>.delayed(processingDelay);
      }
      if (failScansRemaining > 0) {
        failScansRemaining--;
        throw const ScanEngineException('FAKE_FAIL', '模拟原生处理失败');
      }
      final out = File(p.join(outputDir.path, 'native_scan_$scanCount.jpg'));
      out.parent.createSync(recursive: true);
      File(fixturePath).copySync(out.path);
      return ScanResult(
        outputPath: out.path,
        outputFormat: 'jpg',
        sourceWidth: 900,
        sourceHeight: 1200,
        outputWidth: 880,
        outputHeight: 1170,
        fileBytes: await out.length(),
        detected: options.quad != null,
        detectionStage: options.quad == null
            ? detection.detectionStage
            : 'manual',
        autoColorMode: ScanColorMode.grayscale,
        colorMode: options.colorMode,
        quad: options.quad,
        timings: fakeTimings,
      );
    } finally {
      activeScans--;
    }
  }
}

class RecordingPdfExporter implements PdfExporter {
  ScanDocument? document;
  String? outputPath;
  bool? fitA4;
  List<String> pageIds = <String>[];
  int calls = 0;

  @override
  Future<PdfExportResult> export(
    ScanDocument document, {
    required String outputPath,
    required bool fitA4,
    PdfProgressCallback? onProgress,
  }) async {
    calls++;
    this.document = document;
    this.outputPath = outputPath;
    this.fitA4 = fitA4;
    pageIds = document.pages.map((page) => page.id).toList(growable: false);
    onProgress?.call(
      PdfExportProgress(
        donePages: document.pages.length,
        totalPages: document.pages.length,
        currentLabel: '完成',
      ),
    );
    final file = File(outputPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('%PDF-1.4 fake');
    return PdfExportResult(
      path: outputPath,
      bytes: file.lengthSync(),
      pageCount: document.pages.length,
      pageSizesPt: List<(double, double)>.filled(document.pages.length, (
        595.0,
        842.0,
      )),
      elapsed: const Duration(milliseconds: 5),
    );
  }
}

/// Test-only store whose file operations complete synchronously inside the
/// method body, so widget tests under fake async do not wait on the real I/O
/// event loop for controller mutations triggered from the UI.
class SyncSessionStore extends SessionStore {
  SyncSessionStore({required super.root});

  String _ext(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.jpeg' || ext == '.png' ? ext : '.jpg';
  }

  @override
  Future<ScanDocument> createDocument({String? title, DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    final id = 'doc_${timestamp.microsecondsSinceEpoch.toRadixString(36)}';
    final document = ScanDocument(
      id: id,
      title: title ?? defaultDocumentTitle(timestamp),
      createdAt: timestamp,
      updatedAt: timestamp,
      pages: const <ScanPage>[],
    );
    Directory(p.join(documentsDir.path, id, 'originals'))
        .createSync(recursive: true);
    Directory(p.join(documentsDir.path, id, 'processed'))
        .createSync(recursive: true);
    await save(document);
    return document;
  }

  @override
  Future<List<ScanDocument>> listDocuments() async {
    if (!documentsDir.existsSync()) return const <ScanDocument>[];
    final documents = <ScanDocument>[];
    for (final entity in documentsDir.listSync()) {
      if (entity is! Directory) continue;
      final file = File(p.join(entity.path, 'session.json'));
      if (!file.existsSync()) continue;
      try {
        final raw = jsonDecode(file.readAsStringSync());
        if (raw is Map<String, dynamic>) {
          documents.add(ScanDocument.fromJson(raw));
        }
      } catch (_) {
        // Corrupt test session; ignore.
      }
    }
    documents.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return documents;
  }

  @override
  Future<ScanDocument?> loadById(String id) async {
    final file = sessionFile(id);
    if (!file.existsSync()) return null;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is Map<String, dynamic>) return ScanDocument.fromJson(raw);
    } catch (_) {
      // Corrupt test session; ignore.
    }
    return null;
  }

  @override
  Future<void> save(ScanDocument document) async {
    final file = sessionFile(document.id);
    file.parent.createSync(recursive: true);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(
      const JsonEncoder().convert(document.toJson()),
      flush: true,
    );
    if (file.existsSync()) file.deleteSync();
    temp.renameSync(file.path);
  }

  @override
  Future<String> saveOriginal(
    String documentId,
    String pageId,
    String sourcePath,
  ) async {
    final target = File(
      p.join(
        documentsDir.path,
        documentId,
        'originals',
        '$pageId${_ext(sourcePath)}',
      ),
    );
    target.parent.createSync(recursive: true);
    File(sourcePath).copySync(target.path);
    return target.path;
  }

  @override
  Future<String> saveProcessed(
    String documentId,
    String pageId,
    String sourcePath,
  ) async {
    final version = DateTime.now().microsecondsSinceEpoch;
    final target = File(
      p.join(
        documentsDir.path,
        documentId,
        'processed',
        '${pageId}_$version${_ext(sourcePath)}',
      ),
    );
    target.parent.createSync(recursive: true);
    File(sourcePath).copySync(target.path);
    return target.path;
  }

  @override
  Future<String> exportPath(String fileName) async {
    exportsDir.createSync(recursive: true);
    return p.join(exportsDir.path, fileName);
  }

  @override
  Future<void> deletePageFiles(ScanDocument document, ScanPage page) async {
    for (final path in [page.originalPath, page.processedPath]) {
      if (path == null) continue;
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

String fixtureJpegPath() => p.absolute('test_assets/fixtures/page.jpg');
