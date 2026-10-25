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

  test('SettingsStore 遇到合法但非对象的 JSON 时回落默认值', () async {
    final temp = await Directory.systemTemp.createTemp('scanner_settings_shape_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final store = SettingsStore(root: temp);

    // `{broken` 是非 JSON；这里覆盖“能解析但顶层不是对象”的情况，
    // 例如用户手改配置成数组、字符串、数字或 null。
    for (final raw in <String>['[]', '["nope"]', '"nope"', '42', 'null']) {
      await store.file.writeAsString(raw);
      final settings = await store.load();
      expect(
        settings.defaultColorMode,
        ScanColorMode.grayscale,
        reason: 'raw=$raw 应回落灰度',
      );
      expect(
        settings.defaultCropMode,
        DefaultCropMode.auto,
        reason: 'raw=$raw 应回落自动裁切',
      );
    }
  });
}
