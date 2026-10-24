import 'package:fairscan_engine/fairscan_engine.dart';

/// Where the final four corners for a page came from.
///
/// The wire names are persisted in `session.json`, so they must stay stable.
enum QuadSource {
  import('import'),
  capture('capture'),
  paperOuter('paper_outer'),
  fallback('default'),
  manual('manual');

  const QuadSource(this.wireName);

  final String wireName;

  static QuadSource fromWire(String? value) => QuadSource.values.firstWhere(
    (source) => source.wireName == value,
    orElse: () => QuadSource.fallback,
  );

  String get label => switch (this) {
    QuadSource.import => 'IMPORT 自动检测',
    QuadSource.capture => 'CAPTURE 自动检测',
    QuadSource.paperOuter => '纸面外框（保留整张纸面）',
    QuadSource.fallback => '默认四角（整图内缩 2%）',
    QuadSource.manual => '手动四角',
  };

  String get shortLabel => switch (this) {
    QuadSource.import || QuadSource.capture => '检测框',
    QuadSource.paperOuter => '纸面外框',
    QuadSource.fallback => '整图 2%',
    QuadSource.manual => '手动四角',
  };
}

enum PageStatus {
  queued,
  processing,
  done,
  failed;

  static PageStatus fromWire(String? value) => PageStatus.values.firstWhere(
    (status) => status.name == value,
    orElse: () => PageStatus.queued,
  );

  String get label => switch (this) {
    PageStatus.queued => '排队中',
    PageStatus.processing => '处理中',
    PageStatus.done => '已完成',
    PageStatus.failed => '失败',
  };
}

/// A captured sheet that is always kept on disk.
///
/// The camera/import output is copied into the document directory before the
/// page enters the queue. Native processing writes to a separate output path,
/// so a failed scan can never overwrite [originalPath].
class ScanPage {
  const ScanPage({
    required this.id,
    required this.originalPath,
    required this.colorMode,
    required this.status,
    required this.createdAt,
    this.shadowFlatten = true,
    this.processedPath,
    this.quad,
    this.quadSource = QuadSource.fallback,
    this.candidates = const <QuadCandidate>[],
    this.needsReview = false,
    this.reviewReason,
    this.detectionScore,
    this.detectionFrameFill,
    this.detectionCoverage,
    this.engineStage,
    this.processingStartedAt,
    this.processedAt,
    this.processingMs,
    this.engineMs,
    this.outputWidth,
    this.outputHeight,
    this.fileBytes,
    this.errorCode,
    this.errorMessage,
    this.captureSource = 'capture',
  });

  factory ScanPage.fromJson(Map<String, dynamic> json) {
    final rawQuad = json['quad'];
    return ScanPage(
      id: json['id'] as String,
      originalPath: json['originalPath'] as String,
      processedPath: json['processedPath'] as String?,
      colorMode: ScanColorMode.fromWire(json['colorMode'] as String?),
      shadowFlatten: json['shadowFlatten'] as bool? ?? true,
      status: PageStatus.fromWire(json['status'] as String?),
      quad: rawQuad is List
          ? rawQuad
                .whereType<List<dynamic>>()
                .map(
                  (p) => ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
                )
                .toList(growable: false)
          : null,
      quadSource: QuadSource.fromWire(json['quadSource'] as String?),
      candidates:
          (json['candidates'] as List?)
              ?.whereType<Map<dynamic, dynamic>>()
              .map(QuadCandidate.fromMap)
              .toList(growable: false) ??
          const <QuadCandidate>[],
      needsReview: json['needsReview'] as bool? ?? false,
      reviewReason: json['reviewReason'] as String?,
      detectionScore: (json['detectionScore'] as num?)?.toDouble(),
      detectionFrameFill: (json['detectionFrameFill'] as num?)?.toDouble(),
      detectionCoverage: (json['detectionCoverage'] as num?)?.toDouble(),
      engineStage: json['engineStage'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      processingStartedAt: _date(json['processingStartedAt']),
      processedAt: _date(json['processedAt']),
      processingMs: (json['processingMs'] as num?)?.toInt(),
      engineMs: (json['engineMs'] as num?)?.toInt(),
      outputWidth: (json['outputWidth'] as num?)?.toInt(),
      outputHeight: (json['outputHeight'] as num?)?.toInt(),
      fileBytes: (json['fileBytes'] as num?)?.toInt(),
      errorCode: json['errorCode'] as String?,
      errorMessage: json['errorMessage'] as String?,
      captureSource: json['captureSource'] as String? ?? 'capture',
    );
  }

  final String id;
  final String originalPath;
  final String? processedPath;
  final ScanColorMode colorMode;
  final bool shadowFlatten;
  final PageStatus status;
  final List<NormalizedPoint>? quad;

  /// The source of the final corners. Persisted for every page.
  final QuadSource quadSource;

  /// Native crop candidates kept so the user can switch after processing.
  final List<QuadCandidate> candidates;
  final bool needsReview;
  final String? reviewReason;
  final double? detectionScore;
  final double? detectionFrameFill;
  final double? detectionCoverage;

  /// Raw engine path (`import` / `capture` / `none`) when detection ran.
  final String? engineStage;
  final DateTime createdAt;
  final DateTime? processingStartedAt;
  final DateTime? processedAt;
  final int? processingMs;
  final int? engineMs;
  final int? outputWidth;
  final int? outputHeight;
  final int? fileBytes;
  final String? errorCode;
  final String? errorMessage;

  /// `capture` or `import`; records how the original got into the session.
  final String captureSource;

  bool get isDone => status == PageStatus.done && processedPath != null;
  bool get hasReviewWarning => needsReview;
  String get displayPath => processedPath ?? originalPath;

  ScanPage copyWith({
    String? originalPath,
    ScanColorMode? colorMode,
    bool? shadowFlatten,
    PageStatus? status,
    List<NormalizedPoint>? quad,
    bool clearQuad = false,
    QuadSource? quadSource,
    List<QuadCandidate>? candidates,
    bool? needsReview,
    String? reviewReason,
    bool clearReviewReason = false,
    double? detectionScore,
    double? detectionFrameFill,
    double? detectionCoverage,
    String? engineStage,
    DateTime? createdAt,
    DateTime? processingStartedAt,
    DateTime? processedAt,
    int? processingMs,
    int? engineMs,
    int? outputWidth,
    int? outputHeight,
    int? fileBytes,
    String? errorCode,
    String? errorMessage,
    bool clearError = false,
    bool clearOutput = false,
    String? captureSource,
    String? processedPath,
    bool clearProcessed = false,
  }) {
    return ScanPage(
      id: id,
      originalPath: originalPath ?? this.originalPath,
      processedPath: clearProcessed
          ? null
          : (processedPath ?? this.processedPath),
      colorMode: colorMode ?? this.colorMode,
      shadowFlatten: shadowFlatten ?? this.shadowFlatten,
      status: status ?? this.status,
      quad: clearQuad ? null : (quad ?? this.quad),
      quadSource: quadSource ?? this.quadSource,
      candidates: candidates ?? this.candidates,
      needsReview: needsReview ?? this.needsReview,
      reviewReason: clearReviewReason
          ? null
          : (reviewReason ?? this.reviewReason),
      detectionScore: clearOutput
          ? null
          : (detectionScore ?? this.detectionScore),
      detectionFrameFill: clearOutput
          ? null
          : (detectionFrameFill ?? this.detectionFrameFill),
      detectionCoverage: clearOutput
          ? null
          : (detectionCoverage ?? this.detectionCoverage),
      engineStage: clearOutput ? null : (engineStage ?? this.engineStage),
      createdAt: createdAt ?? this.createdAt,
      processingStartedAt: clearOutput
          ? null
          : (processingStartedAt ?? this.processingStartedAt),
      processedAt: clearOutput ? null : (processedAt ?? this.processedAt),
      processingMs: clearOutput ? null : (processingMs ?? this.processingMs),
      engineMs: clearOutput ? null : (engineMs ?? this.engineMs),
      outputWidth: clearOutput ? null : (outputWidth ?? this.outputWidth),
      outputHeight: clearOutput ? null : (outputHeight ?? this.outputHeight),
      fileBytes: clearOutput ? null : (fileBytes ?? this.fileBytes),
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      captureSource: captureSource ?? this.captureSource,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'originalPath': originalPath,
    'processedPath': processedPath,
    'colorMode': colorMode.wireName,
    'shadowFlatten': shadowFlatten,
    'status': status.name,
    'quad': quad?.map((p) => <double>[p.$1, p.$2]).toList(growable: false),
    'quadSource': quadSource.wireName,
    'candidates': candidates
        .map((candidate) => candidate.toMap())
        .toList(growable: false),
    'needsReview': needsReview,
    'reviewReason': reviewReason,
    'detectionScore': detectionScore,
    'detectionFrameFill': detectionFrameFill,
    'detectionCoverage': detectionCoverage,
    'engineStage': engineStage,
    'createdAt': createdAt.toIso8601String(),
    'processingStartedAt': processingStartedAt?.toIso8601String(),
    'processedAt': processedAt?.toIso8601String(),
    'processingMs': processingMs,
    'engineMs': engineMs,
    'outputWidth': outputWidth,
    'outputHeight': outputHeight,
    'fileBytes': fileBytes,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
    'captureSource': captureSource,
  };

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

/// One ordered document session. Every mutation produces a new instance so
/// the persistence layer can save a consistent snapshot.
class ScanDocument {
  const ScanDocument({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.pages,
    this.exportedAt,
    this.lastExportPath,
  });

  factory ScanDocument.fromJson(Map<String, dynamic> json) {
    final rawPages = json['pages'];
    return ScanDocument(
      id: json['id'] as String,
      title: json['title'] as String? ?? '扫描文档',
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      pages: rawPages is List
          ? rawPages
                .whereType<Map<dynamic, dynamic>>()
                .map((p) => ScanPage.fromJson(Map<String, dynamic>.from(p)))
                .toList(growable: false)
          : const <ScanPage>[],
      exportedAt: _date(json['exportedAt']),
      lastExportPath: json['lastExportPath'] as String?,
    );
  }

  static const int schemaVersion = 2;

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ScanPage> pages;
  final DateTime? exportedAt;
  final String? lastExportPath;

  bool get isExported => exportedAt != null;
  bool get hasPages => pages.isNotEmpty;
  bool get hasPending => pages.any(
    (p) => p.status == PageStatus.queued || p.status == PageStatus.processing,
  );
  bool get hasFailures => pages.any((p) => p.status == PageStatus.failed);
  bool get hasReviewWarnings => pages.any((p) => p.needsReview);
  bool get canExport => pages.isNotEmpty && pages.every((page) => page.isDone);

  int pageNumber(String pageId) => pages.indexWhere((p) => p.id == pageId) + 1;

  ScanDocument copyWith({
    String? title,
    DateTime? updatedAt,
    List<ScanPage>? pages,
    DateTime? exportedAt,
    bool clearExportedAt = false,
    String? lastExportPath,
  }) {
    return ScanDocument(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pages: pages ?? this.pages,
      exportedAt: clearExportedAt ? null : (exportedAt ?? this.exportedAt),
      lastExportPath: lastExportPath ?? this.lastExportPath,
    );
  }

  /// Replaces one page while keeping its position and all other fields.
  ScanDocument replacePage(ScanPage page) => copyWith(
    updatedAt: DateTime.now(),
    exportedAt: null,
    clearExportedAt: true,
    pages: [
      for (final current in pages)
        if (current.id == page.id) page else current,
    ],
  );

  ScanDocument removePage(String pageId) => copyWith(
    updatedAt: DateTime.now(),
    exportedAt: null,
    clearExportedAt: true,
    pages: pages.where((page) => page.id != pageId).toList(growable: false),
  );

  /// Moves [from] to final index [to]. Both indexes are in the original list.
  ScanDocument movePage(int from, int to) {
    if (from < 0 || from >= pages.length || to < 0 || to >= pages.length) {
      return this;
    }
    if (from == to) return this;
    final next = List<ScanPage>.of(pages);
    final page = next.removeAt(from);
    next.insert(to, page);
    return copyWith(
      updatedAt: DateTime.now(),
      exportedAt: null,
      clearExportedAt: true,
      pages: next,
    );
  }

  ScanDocument clearExportMarker() => copyWith(
    updatedAt: DateTime.now(),
    exportedAt: null,
    clearExportedAt: true,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'pages': pages.map((p) => p.toJson()).toList(growable: false),
    'exportedAt': exportedAt?.toIso8601String(),
    'lastExportPath': lastExportPath,
  };

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

/// Fallback corners for the whole frame, inset by 2% so the warp never samples
/// outside the image. Used when detection is missing, weak, or only covers a
/// small part of the preview.
const List<NormalizedPoint> kDefaultInsetQuad = <NormalizedPoint>[
  (0.02, 0.02),
  (0.98, 0.02),
  (0.98, 0.98),
  (0.02, 0.98),
];
