import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homework_scanner/services/session_store.dart';
import 'package:path/path.dart' as p;

void main() {
  test('listDocuments 按 updatedAt 从新到旧排序并跳过损坏 session', () async {
    final root = await Directory.systemTemp.createTemp('scanner_session_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = SessionStore(root: root);

    final older = await store.createDocument(
      title: '较早',
      now: DateTime(2026, 1, 1, 9),
    );
    final oldest = await store.createDocument(
      title: '最早',
      now: DateTime(2026, 1, 1, 8),
    );
    final newest = await store.createDocument(
      title: '最新',
      now: DateTime(2026, 1, 2, 20),
    );

    // 目录存在但 session.json 只写了一半：文档库必须跳过它而不是启动失败。
    final corruptDir = Directory(
      p.join(store.documentsDir.path, 'doc_corrupt'),
    );
    await corruptDir.create(recursive: true);
    await File(
      p.join(corruptDir.path, 'session.json'),
    ).writeAsString('{broken');

    final documents = await store.listDocuments();

    expect(documents.map((document) => document.id), [
      newest.id,
      older.id,
      oldest.id,
    ]);
    expect(documents.map((document) => document.title), ['最新', '较早', '最早']);
    expect(documents.map((document) => document.updatedAt), [
      DateTime(2026, 1, 2, 20),
      DateTime(2026, 1, 1, 9),
      DateTime(2026, 1, 1, 8),
    ]);
  });
}
