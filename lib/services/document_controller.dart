import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/scan_document.dart';
import 'pdf_export_service.dart';
import 'session_store.dart';

/// Confidence below this means the detected frame may clip page content.
const double kAutoQuadScoreThreshold = 0.85;

/// A frame that covers less than half of the photo is usually a strip of a
/// page (or one half of an open notebook), not a full sheet.
const double kAutoQuadMinFrameFill = 0.50;

/// The output engine budget used for every page in Sprint 2 (same 4 MP as the
/// Sprint 1 accepted setting). Black-and-white uses the engine's 4x multiplier.
const int kPageMaxPixels = 4000000;

class _QuadChoice {
  const _QuadChoice({
    required this.quad,
    required this.source,
    required this.needsReview,
    this.reason,
    this.detection,
    this.candidates = const <QuadCandidate>[],
  });

  final List<NormalizedPoint> quad;
  final QuadSource source;
  final bool needsReview;
  final String? reason;
  final DetectResult? detection;
  final List<QuadCandidate> candidates;
}

/// Owns one document session and a serial native-processing queue.
///
/// Camera captures call [addCapturedPage] and return immediately; the file copy
/// and detection/scan happen later. Only one page is ever inside the Kotlin
/// engine, which keeps peak native memory bounded while the user keeps shooting.
class DocumentController extends ChangeNotifier {
  DocumentController({
    required this.engine,
    required this.store,
    required this.exporter,
    this.defaultColorMode = ScanColorMode.auto,
    this.maxPixels = kPageMaxPixels,
  });

  final ScanEngine engine;
  final SessionStore store;
  final PdfExporter exporter;
  final ScanColorMode defaultColorMode;
  final int maxPixels;

  ScanDocument? _document;
  bool _loading = true;
  bool _exporting = false;
  String? _fatalError;
  String? _lastOperationError;
  PdfExportProgress? _exportProgress;
  PdfExportResult? _lastExport;
  bool _disposed = false;

  final List<String> _queue = <String>[];
  bool _draining = false;
  Completer<void>? _idleCompleter;
  Future<void> _ingestChain = Future<void>.value();
  Future<void> _saveChain = Future<void>.value();

  ScanDocument? get document => _document;
  bool get isLoading => _loading;
  bool get isExporting => _exporting;
  bool get isProcessing => _draining || _queue.isNotEmpty;
  int get queuedCount => _queue.length;
  String? get fatalError => _fatalError;
  String? get lastOperationError => _lastOperationError;
  PdfExportProgress? get exportProgress => _exportProgress;
  PdfExportResult? get lastExport => _lastExport;
  bool get canExport => _document?.canExport ?? false;

  Future<void> initialize({bool recover = true}) async {
    try {
      await store.documentsDir.create(recursive: true);
      ScanDocument? loaded = recover ? await store.loadRecoverable() : null;
      loaded ??= await store.createDocument();
      await _activateDocument(loaded);
    } catch (error) {
      _loading = false;
      _fatalError = '$error';
      _notify();
    }
  }

  /// Opens an existing document from the home library. Waits for any current
  /// queue to finish so pages from two documents never enter the engine at once.
  Future<void> openDocument(String documentId) async {
    if (_exporting) throw StateError('正在导出，请稍后再切换文档');
    await waitForIdle();
    final loaded = await store.loadById(documentId);
    if (loaded == null) throw StateError('文档不存在或已损坏');
    _loading = true;
    _fatalError = null;
    _lastOperationError = null;
    _lastExport = null;
    _notify();
    await _activateDocument(loaded);
  }

  Future<void> _activateDocument(ScanDocument loaded) async {
    _document = loaded;
    _loading = false;
    _notify();

    // A killed process leaves pages in `processing`. Requeue those, plus
    // completed pages whose output vanished; failed pages stay failed until
    // the user explicitly retries.
    final resumed = <String>[];
    for (final page in loaded.pages) {
      final missingOutput =
          page.status == PageStatus.done &&
          (page.processedPath == null ||
              !File(page.processedPath!).existsSync());
      if (page.status == PageStatus.queued ||
          page.status == PageStatus.processing ||
          missingOutput) {
        final pageIndex = _document!.pages.indexWhere((p) => p.id == page.id);
        if (pageIndex >= 0) {
          _replacePageAt(
            pageIndex,
            page.copyWith(
              status: PageStatus.queued,
              clearError: true,
              needsReview: page.needsReview,
            ),
            touchExport: false,
          );
          resumed.add(page.id);
        }
      }
    }
    if (resumed.isNotEmpty) {
      await _persist();
      for (final id in resumed) {
        _enqueue(id);
      }
    }
    unawaited(
      engine.initialize().catchError((Object error) {
        _lastOperationError = '扫描引擎初始化失败：$error';
        _notify();
      }),
    );
  }

  /// Adds a camera/import file in call order and returns the newly queued page.
  /// The camera should not await this: the UI stays live while the copy and the
  /// native scan run in the background.
  Future<ScanPage> addCapturedPage(
    String sourcePath, {
    String captureSource = 'capture',
    ScanColorMode? colorMode,
  }) {
    return _serialIngest(() async {
      final initialDocument = _requireDocument();
      final now = DateTime.now();
      final pageId = _newId('page', now);
      final originalPath = await store.saveOriginal(
        initialDocument.id,
        pageId,
        sourcePath,
      );
      // Re-read after the await: another page may have finished processing
      // while the 12 MP file was being copied. Committing the old snapshot
      // would roll that page back to `processing`.
      final document = _requireDocument();
      final page = ScanPage(
        id: pageId,
        originalPath: originalPath,
        colorMode: colorMode ?? defaultColorMode,
        status: PageStatus.queued,
        createdAt: now,
        captureSource: captureSource,
      );
      _document = document.copyWith(
        updatedAt: now,
        exportedAt: null,
        clearExportedAt: true,
        pages: [...document.pages, page],
      );
      _notify();
      await _persist();
      _enqueue(page.id);
      return page;
    });
  }

  /// Imports multiple gallery paths in the order the user selected them.
  Future<List<ScanPage>> addCapturedPages(
    List<String> sourcePaths, {
    String captureSource = 'import',
    ScanColorMode? colorMode,
  }) async {
    final pages = <ScanPage>[];
    for (final path in sourcePaths) {
      pages.add(
        await addCapturedPage(
          path,
          captureSource: captureSource,
          colorMode: colorMode,
        ),
      );
    }
    return pages;
  }

  /// Replaces an existing page's original and keeps its position/number.
  Future<void> retakePage(String pageId, String sourcePath) {
    return _serialIngest(() async {
      final document = _requireDocument();
      final index = document.pages.indexWhere((page) => page.id == pageId);
      if (index < 0) throw StateError('页面不存在: $pageId');
      final old = document.pages[index];
      final newOriginal = await store.saveOriginal(
        document.id,
        pageId,
        sourcePath,
      );
      if (p.normalize(old.originalPath) != p.normalize(newOriginal)) {
        await _deleteQuietly(old.originalPath);
      }
      await _deleteQuietly(old.processedPath);
      _replacePageAt(
        index,
        old.copyWith(
          originalPath: newOriginal,
          createdAt: DateTime.now(),
          status: PageStatus.queued,
          clearQuad: true,
          clearProcessed: true,
          clearOutput: true,
          quadSource: QuadSource.fallback,
          needsReview: false,
          clearReviewReason: true,
          clearError: true,
          captureSource: 'capture',
        ),
      );
      await _persist();
      _enqueue(pageId);
    });
  }

  Future<void> retryPage(String pageId) async {
    final index = _indexOf(pageId);
    if (index < 0) return;
    final page = _document!.pages[index];
    _replacePageAt(
      index,
      page.copyWith(status: PageStatus.queued, clearError: true),
    );
    _notify();
    await _persist();
    _enqueue(pageId);
  }

  Future<void> setColorMode(String pageId, ScanColorMode mode) async {
    final index = _indexOf(pageId);
    if (index < 0) return;
    final page = _document!.pages[index];
    if (page.colorMode == mode && page.status != PageStatus.failed) return;
    _replacePageAt(
      index,
      page.copyWith(
        colorMode: mode,
        status: PageStatus.queued,
        clearError: true,
      ),
    );
    _notify();
    await _persist();
    _enqueue(pageId);
  }

  Future<void> setShadowFlatten(String pageId, bool enabled) async {
    final index = _indexOf(pageId);
    if (index < 0) return;
    final page = _document!.pages[index];
    if (page.shadowFlatten == enabled && page.status != PageStatus.failed) {
      return;
    }
    _replacePageAt(
      index,
      page.copyWith(
        shadowFlatten: enabled,
        status: PageStatus.queued,
        clearError: true,
      ),
    );
    _notify();
    await _persist();
    _enqueue(pageId);
  }

  Future<void> setManualQuad(String pageId, List<NormalizedPoint> quad) async {
    if (quad.length != 4) {
      throw ArgumentError.value(quad.length, 'quad', '四角必须正好 4 个点');
    }
    final index = _indexOf(pageId);
    if (index < 0) return;
    final page = _document!.pages[index];
    final oldProcessed = page.processedPath;
    _replacePageAt(
      index,
      page.copyWith(
        quad: List<NormalizedPoint>.unmodifiable(quad),
        quadSource: QuadSource.manual,
        needsReview: false,
        clearReviewReason: true,
        status: PageStatus.queued,
        clearError: true,
        clearProcessed: true,
        clearOutput: true,
      ),
    );
    _notify();
    await _persist();
    await _deleteQuietly(oldProcessed);
    _enqueue(pageId);
  }

  /// One-tap "use the safe default" action for a flagged page.
  Future<void> useDefaultQuad(String pageId) async {
    final index = _indexOf(pageId);
    if (index < 0) return;
    final page = _document!.pages[index];
    final oldProcessed = page.processedPath;
    _replacePageAt(
      index,
      page.copyWith(
        quad: kDefaultInsetQuad,
        quadSource: QuadSource.fallback,
        needsReview: false,
        clearReviewReason: true,
        status: PageStatus.queued,
        clearError: true,
        clearProcessed: true,
        clearOutput: true,
      ),
    );
    _notify();
    await _persist();
    await _deleteQuietly(oldProcessed);
    _enqueue(pageId);
  }

  /// Switches to one of the native candidates without opening the drag editor.
  Future<void> applyCandidate(String pageId, QuadCandidate candidate) async {
    if (candidate.quad.length != 4) {
      throw ArgumentError.value(
        candidate.quad.length,
        'candidate.quad',
        '四角必须正好 4 个点',
      );
    }
    final index = _indexOf(pageId);
    if (index < 0) return;
    final page = _document!.pages[index];
    final oldProcessed = page.processedPath;
    final source = _sourceFor(candidate.source);
    final lowContent = candidate.coverage < 0.97;
    final review =
        source == QuadSource.paperOuter ||
        source == QuadSource.fallback ||
        lowContent;
    final reason = lowContent
        ? '该候选只保留约 ${(candidate.coverage * 100).round()}% 的可检测纸面，可能切边'
        : source == QuadSource.paperOuter
        ? '已切换到纸面外框（保留整页/整本），建议检查边缘'
        : source == QuadSource.fallback
        ? '已切换到整图内缩 2%，建议检查四角'
        : null;
    _replacePageAt(
      index,
      page.copyWith(
        quad: List<NormalizedPoint>.unmodifiable(candidate.quad),
        quadSource: source,
        candidates: page.candidates,
        needsReview: review,
        reviewReason: reason,
        clearReviewReason: reason == null,
        status: PageStatus.queued,
        clearError: true,
        clearProcessed: true,
        clearOutput: true,
      ),
    );
    _notify();
    await _persist();
    await _deleteQuietly(oldProcessed);
    _enqueue(pageId);
  }

  Future<void> deletePage(String pageId) async {
    final document = _document;
    if (document == null) return;
    final index = _indexOf(pageId);
    if (index < 0) return;
    final removed = document.pages[index];
    _document = document.removePage(pageId);
    _queue.remove(pageId);
    _notify();
    await _persist();
    await store.deletePageFiles(document, removed);
  }

  /// Moves the page at [from] to final index [to], matching ReorderableListView
  /// indexes after normalisation by the UI.
  Future<void> movePage(int from, int to) async {
    final document = _document;
    if (document == null) return;
    if (from < 0 || from >= document.pages.length) return;
    if (to < 0 || to >= document.pages.length) return;
    _document = document.movePage(from, to);
    _notify();
    await _persist();
  }

  Future<void> startNewDocument() async {
    if (isProcessing) {
      throw StateError('还有页面在处理，完成后再新建文档');
    }
    _document = await store.createDocument();
    _document = _document!.clearExportMarker();
    await _persist();
    _notify();
  }

  Future<PdfExportResult> exportPdf({
    required String fileName,
    required bool fitA4,
  }) async {
    if (_exporting) {
      throw const PdfExportException('EXPORT_BUSY', '正在导出，请稍候');
    }
    final document = _requireDocument();
    if (!document.canExport) {
      throw const PdfExportException('PAGES_NOT_READY', '所有页面处理完成后才能导出');
    }
    final normalized = normalizePdfFileName(fileName);
    final path = await store.exportPath(normalized);
    _exporting = true;
    _exportProgress = PdfExportProgress(
      donePages: 0,
      totalPages: document.pages.length,
      currentLabel: '准备',
    );
    _notify();
    try {
      final result = await exporter.export(
        document,
        outputPath: path,
        fitA4: fitA4,
        onProgress: (progress) {
          _exportProgress = progress;
          _notify();
        },
      );
      _lastExport = result;
      _document = _document!.copyWith(
        exportedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        lastExportPath: result.path,
      );
      await _persist();
      _notify();
      return result;
    } finally {
      _exporting = false;
      _exportProgress = null;
      _notify();
    }
  }

  Future<void> waitForIdle() {
    if (!isProcessing) return Future<void>.value();
    _idleCompleter ??= Completer<void>();
    return _idleCompleter!.future;
  }

  ScanPage? pageById(String id) {
    final pages = _document?.pages;
    if (pages == null) return null;
    for (final page in pages) {
      if (page.id == id) return page;
    }
    return null;
  }

  void _enqueue(String pageId) {
    if (!_queue.contains(pageId)) _queue.add(pageId);
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    _notify();
    try {
      while (_queue.isNotEmpty) {
        final pageId = _queue.removeAt(0);
        final page = pageById(pageId);
        if (page == null || page.status != PageStatus.queued) continue;
        await _processPage(pageId);
      }
    } finally {
      _draining = false;
      _notify();
      final completer = _idleCompleter;
      _idleCompleter = null;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
  }

  Future<void> _processPage(String pageId) async {
    var page = pageById(pageId);
    if (page == null) return;
    final index = _indexOf(pageId);
    if (index < 0) return;
    final firstRun = page.processedAt == null;
    final startedAt = DateTime.now();
    // First completion measures shutter/import -> done (queue wait included);
    // later reprocesses measure only the new native pass.
    final timingStart = firstRun ? page.createdAt : startedAt;
    page = page.copyWith(
      status: PageStatus.processing,
      processingStartedAt: startedAt,
      clearError: true,
    );
    _replacePageAt(index, page);
    _notify();
    await _persist();

    final wall = Stopwatch()..start();
    try {
      List<NormalizedPoint>? chosenQuad = page.quad;
      var source = page.quadSource;
      var needsReview = page.needsReview;
      String? reason = page.reviewReason;
      double? detectionScore = page.detectionScore;
      double? frameFill = page.detectionFrameFill;
      double? coverage = page.detectionCoverage;
      String? engineStage = page.engineStage;
      var candidates = page.candidates;
      DetectResult? detection;

      // Reprocessing (colour/retry) keeps the already accepted corners. Only a
      // brand-new page, or a page whose first attempt died before choosing
      // corners, runs detection again.
      if (chosenQuad == null) {
        detection = await engine.detectDocument(page.originalPath);
        final choice = _chooseQuad(detection);
        chosenQuad = choice.quad;
        source = choice.source;
        needsReview = choice.needsReview;
        reason = choice.reason;
        detectionScore = choice.detection?.score;
        frameFill = choice.detection?.frameFill;
        coverage = choice.detection?.coverage;
        engineStage = choice.detection?.detectionStage;
        candidates = choice.candidates;
      }

      final result = await engine.scan(
        page.originalPath,
        options: ScanOptions(
          colorMode: page.colorMode,
          shadowFlatten: page.shadowFlatten,
          maxPixels: maxPixels,
          quad: chosenQuad,
        ),
      );
      final current = pageById(pageId);
      if (current == null) return; // deleted while the engine was running
      final processedPath = await store.saveProcessed(
        _requireDocument().id,
        pageId,
        result.outputPath,
      );
      await _deleteQuietly(result.outputPath);
      // Keep the previous result until the new copy succeeded, then remove it.
      // The new path also invalidates Flutter's path-keyed ImageCache.
      final previousProcessedPath = current.processedPath;
      if (previousProcessedPath != null &&
          previousProcessedPath != processedPath) {
        await _deleteQuietly(previousProcessedPath);
      }

      final processedIndex = _indexOf(pageId);
      if (processedIndex < 0) return;
      _replacePageAt(
        processedIndex,
        current.copyWith(
          processedPath: processedPath,
          status: PageStatus.done,
          quad: chosenQuad,
          quadSource: source,
          candidates: candidates,
          needsReview: needsReview,
          reviewReason: reason,
          clearReviewReason: reason == null,
          detectionScore: detectionScore,
          detectionFrameFill: frameFill,
          detectionCoverage: coverage,
          engineStage: engineStage,
          processedAt: DateTime.now(),
          processingMs: DateTime.now().difference(timingStart).inMilliseconds,
          engineMs: result.timings.totalMs,
          outputWidth: result.outputWidth,
          outputHeight: result.outputHeight,
          fileBytes: result.fileBytes,
          clearError: true,
        ),
      );
      wall.stop();
      debugPrint(
        'PAGE_TRACE id=$pageId source=${source.wireName} '
        'needsReview=$needsReview detect=${detection?.detectionStage ?? engineStage} '
        'wallMs=${wall.elapsedMilliseconds} engineMs=${result.timings.totalMs} '
        'size=${result.outputWidth}x${result.outputHeight} '
        'bytes=${result.fileBytes}',
      );
      _notify();
      await _persist();
    } catch (error) {
      wall.stop();
      final failedIndex = _indexOf(pageId);
      if (failedIndex < 0) return;
      final current = _document!.pages[failedIndex];
      final code = error is ScanEngineException ? error.code : 'UNEXPECTED';
      final message = error is ScanEngineException ? error.message : '$error';
      _replacePageAt(
        failedIndex,
        current.copyWith(
          status: PageStatus.failed,
          errorCode: code,
          errorMessage: message,
          processingMs: DateTime.now().difference(timingStart).inMilliseconds,
        ),
      );
      debugPrint(
        'PAGE_FAIL id=$pageId code=$code wallMs=${wall.elapsedMilliseconds} '
        'message=$message',
      );
      _lastOperationError = '第 ${failedIndex + 1} 页处理失败：$message';
      _notify();
      await _persist();
    }
  }

  _QuadChoice _chooseQuad(DetectResult detection) {
    final candidates = _candidatesFromDetection(detection);
    final preserving = candidates
        .where(
          (candidate) =>
              candidate.quad.length == 4 &&
              candidate.coverage >= 0.97 &&
              candidate.frameFill >= kAutoQuadMinFrameFill,
        )
        .toList(growable: false);

    // Normal high-confidence detections stay first so Sprint 2 behaviour is
    // unchanged for easy pages.
    final auto =
        preserving
            .where(
              (candidate) =>
                  _sourceFor(candidate.source) == QuadSource.import ||
                  _sourceFor(candidate.source) == QuadSource.capture,
            )
            .where(
              (candidate) =>
                  candidate.score >= kAutoQuadScoreThreshold &&
                  candidate.background <= 0.35,
            )
            .toList()
          ..sort((a, b) => a.background.compareTo(b.background));
    if (auto.isNotEmpty) {
      return _QuadChoice(
        quad: auto.first.quad,
        source: _sourceFor(auto.first.source),
        needsReview: false,
        candidates: candidates,
        detection: detection,
      );
    }

    // An open notebook often produces a single-page detector quad. The native
    // whole-paper candidate keeps both pages; it is preferred whenever it
    // preserves more paper and is not mostly desk.
    final outer =
        preserving
            .where(
              (candidate) =>
                  _sourceFor(candidate.source) == QuadSource.paperOuter,
            )
            .where((candidate) => candidate.background <= 0.65)
            .toList()
          ..sort((a, b) => a.background.compareTo(b.background));
    if (outer.isNotEmpty) {
      return _QuadChoice(
        quad: outer.first.quad,
        source: QuadSource.paperOuter,
        needsReview: true,
        reason: '检测框没有覆盖完整纸面，已改用纸面外框以保留整页/整本，建议检查边缘',
        candidates: candidates,
        detection: detection,
      );
    }

    // A low score can be caused by a low frame fill while the detector still
    // keeps all paper. Prefer that over the desk-filled whole frame, but keep
    // the warning visible.
    final lowConfidence =
        preserving
            .where((candidate) {
              final source = _sourceFor(candidate.source);
              return source == QuadSource.import ||
                  source == QuadSource.capture;
            })
            .where((candidate) => candidate.background <= 0.55)
            .toList()
          ..sort((a, b) => a.background.compareTo(b.background));
    if (lowConfidence.isNotEmpty) {
      return _QuadChoice(
        quad: lowConfidence.first.quad,
        source: _sourceFor(lowConfidence.first.source),
        needsReview: true,
        reason: '检测置信度偏低（${detection.score.toStringAsFixed(2)}），已保留检测纸面，建议检查边缘',
        candidates: candidates,
        detection: detection,
      );
    }

    final fill = detection.frameFill ?? 0;
    final coverage = detection.coverage ?? 0;
    final reason = !detection.detected || detection.quad == null
        ? '未自动检出完整纸张，已用整图内缩 2% 处理，建议检查四角'
        : fill < kAutoQuadMinFrameFill
        ? '检测框只占画面 ${(fill * 100).round()}%，可能只框住纸面一部分，已用整图内缩 2% 兜底'
        : coverage < 0.85
        ? '检测框只覆盖 ${(coverage * 100).round()}% 的纸面，已用整图内缩 2% 兜底'
        : '检测置信度偏低（${detection.score.toStringAsFixed(2)}），已用整图内缩 2% 兜底';
    return _QuadChoice(
      quad: kDefaultInsetQuad,
      source: QuadSource.fallback,
      needsReview: true,
      reason: reason,
      candidates: candidates,
      detection: detection,
    );
  }

  List<QuadCandidate> _candidatesFromDetection(DetectResult detection) {
    if (detection.candidates.isNotEmpty) return detection.candidates;
    final candidates = <QuadCandidate>[];
    final quad = detection.quad;
    if (quad != null && quad.length == 4) {
      candidates.add(
        QuadCandidate(
          source: detection.detectionStage == 'capture' ? 'capture' : 'import',
          quad: quad,
          score: detection.score,
          meanProb: detection.meanProb ?? 0,
          coverage: detection.coverage ?? 0,
          frameFill: detection.frameFill ?? 0,
        ),
      );
    }
    candidates.add(
      const QuadCandidate(
        source: 'default',
        quad: kDefaultInsetQuad,
        score: 0,
        meanProb: 0,
        coverage: 1,
        frameFill: 0.9216,
      ),
    );
    return candidates;
  }

  QuadSource _sourceFor(String source) => switch (source) {
    'import' => QuadSource.import,
    'capture' => QuadSource.capture,
    'paper_outer' => QuadSource.paperOuter,
    _ => QuadSource.fallback,
  };

  void _replacePageAt(int index, ScanPage page, {bool touchExport = true}) {
    final document = _document;
    if (document == null || index < 0 || index >= document.pages.length) {
      return;
    }
    final pages = List<ScanPage>.of(document.pages);
    pages[index] = page;
    if (touchExport) {
      _document = document.copyWith(
        updatedAt: DateTime.now(),
        exportedAt: null,
        clearExportedAt: true,
        pages: pages,
      );
    } else {
      _document = document.copyWith(updatedAt: DateTime.now(), pages: pages);
    }
  }

  int _indexOf(String pageId) =>
      _document?.pages.indexWhere((page) => page.id == pageId) ?? -1;

  ScanDocument _requireDocument() {
    final document = _document;
    if (document == null) {
      throw StateError('文档尚未初始化');
    }
    return document;
  }

  Future<T> _serialIngest<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _ingestChain = _ingestChain.then((_) {}, onError: (Object _) {}).then((
      _,
    ) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _persist() {
    final snapshot = _document;
    if (snapshot == null) return Future<void>.value();
    _saveChain = _saveChain.then((_) {}, onError: (Object _) {}).then((
      _,
    ) async {
      try {
        await store.save(snapshot);
      } catch (error) {
        _lastOperationError = '会话保存失败：$error';
        _notify();
      }
    });
    return _saveChain;
  }

  Future<void> _deleteQuietly(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort clean-up; the session JSON no longer references this file.
    }
  }

  String _newId(String prefix, DateTime timestamp) {
    final random = Random().nextInt(1 << 20).toRadixString(36);
    return '${prefix}_${timestamp.microsecondsSinceEpoch.toRadixString(36)}_$random';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
