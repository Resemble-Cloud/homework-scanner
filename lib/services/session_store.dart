import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/scan_document.dart';

/// Persists a document as `<root>/documents/<id>/session.json` plus sibling
/// `originals/` and `processed/` folders. The JSON is the source of truth after
/// a process kill; the files are never overwritten by a failed scan.
class SessionStore {
  SessionStore({required Directory root}) : root = root.absolute;

  final Directory root;

  Directory get documentsDir => Directory(p.join(root.path, 'documents'));
  Directory get exportsDir => Directory(p.join(root.path, 'exports'));

  File sessionFile(String documentId) =>
      File(p.join(documentsDir.path, documentId, 'session.json'));

  Future<ScanDocument> createDocument({String? title, DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    final id = _newId('doc', timestamp);
    final document = ScanDocument(
      id: id,
      title: title ?? defaultDocumentTitle(timestamp),
      createdAt: timestamp,
      updatedAt: timestamp,
      pages: const <ScanPage>[],
    );
    await Directory(p.join(documentsDir.path, id, 'originals'))
        .create(recursive: true);
    await Directory(p.join(documentsDir.path, id, 'processed'))
        .create(recursive: true);
    await save(document);
    return document;
  }

  Future<void> save(ScanDocument document) async {
    final file = sessionFile(document.id);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(document.toJson()),
      flush: true,
    );
    if (await file.exists()) {
      await file.delete();
    }
    await temp.rename(file.path);
  }

  /// All documents on disk, newest first. Used by the home library.
  Future<List<ScanDocument>> listDocuments() async {
    if (!await documentsDir.exists()) return const <ScanDocument>[];
    final documents = <ScanDocument>[];
    await for (final entity in documentsDir.list()) {
      if (entity is! Directory) continue;
      final file = File(p.join(entity.path, 'session.json'));
      if (!await file.exists()) continue;
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is! Map<String, dynamic>) continue;
        documents.add(ScanDocument.fromJson(raw));
      } catch (_) {
        // A half-written/corrupt session must never prevent the app launching.
      }
    }
    documents.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return documents;
  }

  /// Loads the most recently updated unexported document, if any. Exported
  /// sessions stay on disk as history but are not reopened on cold start.
  Future<ScanDocument?> loadRecoverable() async {
    final documents = await listDocuments();
    for (final document in documents) {
      if (!document.isExported) return document;
    }
    return null;
  }

  Future<ScanDocument?> loadById(String id) async {
    final file = sessionFile(id);
    if (!await file.exists()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      return ScanDocument.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  /// Copies a camera/import file into the document before it is queued. This
  /// makes the original independent of the camera plugin's cache directory.
  Future<String> saveOriginal(
    String documentId,
    String pageId,
    String sourcePath,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('原始图片不存在', sourcePath);
    }
    final extension = _safeExtension(sourcePath);
    final target = File(
      p.join(documentsDir.path, documentId, 'originals', '$pageId$extension'),
    );
    await target.parent.create(recursive: true);
    await source.copy(target.path);
    return target.path;
  }

  /// Copies the engine output into the session folder. The native temp file is
  /// left to the OS cache; the session keeps its own copy for recovery/export.
  Future<String> saveProcessed(
    String documentId,
    String pageId,
    String sourcePath,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('处理结果不存在', sourcePath);
    }
    final extension = _safeExtension(sourcePath);
    // A versioned filename is intentional: Flutter's ImageCache keys by path.
    // Reusing `pageId.jpg` made reprocessed pages keep showing the old bitmap.
    final version = DateTime.now().microsecondsSinceEpoch;
    final target = File(
      p.join(
        documentsDir.path,
        documentId,
        'processed',
        '${pageId}_$version$extension',
      ),
    );
    await target.parent.create(recursive: true);
    await source.copy(target.path);
    return target.path;
  }

  Future<void> deletePageFiles(ScanDocument document, ScanPage page) async {
    for (final path in [page.originalPath, page.processedPath]) {
      if (path == null) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Deleting a UI row must not fail because a temp file is locked.
      }
    }
  }

  Future<String> exportPath(String fileName) async {
    await exportsDir.create(recursive: true);
    return p.join(exportsDir.path, fileName);
  }

  String _newId(String prefix, DateTime timestamp) =>
      '${prefix}_${timestamp.microsecondsSinceEpoch.toRadixString(36)}_'
      '${timestamp.millisecond.toRadixString(36)}';

  String _safeExtension(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.jpg' || ext == '.jpeg' || ext == '.png') return ext;
    return '.jpg';
  }
}

/// Produces the default document title, e.g. `扫描_20261024_2102`.
String defaultDocumentTitle([DateTime? now]) {
  final t = now ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '扫描_${t.year}${two(t.month)}${two(t.day)}_'
      '${two(t.hour)}${two(t.minute)}';
}

/// Produces the default export name, e.g. `扫描_20261024_153012.pdf`.
String defaultPdfFileName([DateTime? now]) {
  final t = now ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '扫描_${t.year}${two(t.month)}${two(t.day)}_'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}.pdf';
}

/// Keeps the UI and filesystem happy without silently replacing the extension.
String normalizePdfFileName(String input, {DateTime? now}) {
  var name = input.trim();
  if (name.isEmpty) return defaultPdfFileName(now);
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (name.toLowerCase().endsWith('.pdf')) {
    name = name.substring(0, name.length - 4);
  }
  if (name.trim().isEmpty) return defaultPdfFileName(now);
  return '${name.trim()}.pdf';
}
