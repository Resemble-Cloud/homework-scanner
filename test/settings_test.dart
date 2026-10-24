import 'dart:io';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homework_scanner/models/scan_settings.dart';
import 'package:homework_scanner/services/settings_store.dart';

void main() {
  test('默认设置为灰度 + 自动裁切', () {
    const settings = ScanSettings();
    expect(settings.defaultColorMode, ScanColorMode.grayscale);
    expect(settings.defaultCropMode, DefaultCropMode.auto);
  });

  test('ScanSettings JSON round-trip', () {
    const settings = ScanSettings(
      defaultColorMode: ScanColorMode.blackAndWhite,
      defaultCropMode: DefaultCropMode.paperOuter,
    );
    final restored = ScanSettings.fromJson(
      Map<String, dynamic>.from(settings.toJson()),
    );
    expect(restored.defaultColorMode, ScanColorMode.blackAndWhite);
    expect(restored.defaultCropMode, DefaultCropMode.paperOuter);
  });

  test('SettingsStore 持久化并在无文件时回落默认值', () async {
    final temp = await Directory.systemTemp.createTemp('scanner_settings_');
    addTearDown(() => temp.delete(recursive: true));
    final store = SettingsStore(root: temp);

    final initial = await store.load();
    expect(initial.defaultColorMode, ScanColorMode.grayscale);
    expect(initial.defaultCropMode, DefaultCropMode.auto);

    await store.save(
      const ScanSettings(
        defaultColorMode: ScanColorMode.grayscale,
        defaultCropMode: DefaultCropMode.detector,
      ),
    );
    final restored = await store.load();
    expect(restored.defaultColorMode, ScanColorMode.grayscale);
    expect(restored.defaultCropMode, DefaultCropMode.detector);

    await store.file.writeAsString('{broken');
    final fallback = await store.load();
    expect(fallback.defaultColorMode, ScanColorMode.grayscale);
    expect(fallback.defaultCropMode, DefaultCropMode.auto);
  });
}
