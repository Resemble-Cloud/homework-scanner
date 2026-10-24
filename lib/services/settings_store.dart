import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/scan_settings.dart';

/// Stores global capture defaults outside any one document session.
class SettingsStore {
  SettingsStore({required Directory root}) : root = root.absolute;

  final Directory root;

  File get file => File(p.join(root.path, 'scan_settings.json'));

  Future<ScanSettings> load() async {
    try {
      if (!await file.exists()) return const ScanSettings();
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return const ScanSettings();
      return ScanSettings.fromJson(raw);
    } catch (_) {
      return const ScanSettings();
    }
  }

  Future<void> save(ScanSettings settings) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(settings.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }
}
