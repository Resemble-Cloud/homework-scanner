import 'package:fairscan_engine/fairscan_engine.dart';

/// Preferred crop strategy for newly captured/imported pages.
///
/// This is deliberately a preference, not a guarantee: a low-content detector
/// frame still gets a "建议检查" warning even when the user picked [detector].
enum DefaultCropMode {
  auto('auto', '自动（推荐）', '优先保证纸面不丢，再减少桌面'),
  detector('detector', '检测框', '优先用检测框；可能切边时会提示检查'),
  paperOuter('paper_outer', '纸面外框', '优先框住整张纸面，通常带少量桌面'),
  whole('default', '整图 2%', '保留整张照片，只裁掉边缘 2%');

  const DefaultCropMode(this.wireName, this.label, this.description);

  final String wireName;
  final String label;
  final String description;

  static DefaultCropMode fromWire(String? value) =>
      DefaultCropMode.values.firstWhere(
        (mode) => mode.wireName == value,
        orElse: () => DefaultCropMode.auto,
      );
}

/// Global defaults used when a new page enters a document. Changing these never
/// mutates existing pages.
class ScanSettings {
  const ScanSettings({
    this.defaultColorMode = ScanColorMode.grayscale,
    this.defaultCropMode = DefaultCropMode.auto,
  });

  factory ScanSettings.fromJson(Map<String, dynamic> json) => ScanSettings(
    defaultColorMode: ScanColorMode.fromWire(
      json['defaultColorMode'] as String?,
    ),
    defaultCropMode: DefaultCropMode.fromWire(
      json['defaultCropMode'] as String?,
    ),
  );

  final ScanColorMode defaultColorMode;
  final DefaultCropMode defaultCropMode;

  ScanSettings copyWith({
    ScanColorMode? defaultColorMode,
    DefaultCropMode? defaultCropMode,
  }) => ScanSettings(
    defaultColorMode: defaultColorMode ?? this.defaultColorMode,
    defaultCropMode: defaultCropMode ?? this.defaultCropMode,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'defaultColorMode': defaultColorMode.wireName,
    'defaultCropMode': defaultCropMode.wireName,
  };
}
