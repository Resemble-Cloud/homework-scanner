import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/material.dart';

import '../../models/scan_settings.dart';
import '../../services/document_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final DocumentController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final settings = controller.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('扫描设置')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '默认色彩',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '只影响之后新拍或新导入的页面',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final mode in ScanColorMode.values)
                            ChoiceChip(
                              key: Key('settings-color-${mode.wireName}'),
                              label: Text(_colorLabel(mode)),
                              selected: settings.defaultColorMode == mode,
                              onSelected: (_) => controller.updateSettings(
                                settings.copyWith(defaultColorMode: mode),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '默认裁切',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '自动会优先保证纸面不丢；选“检测框”可能更紧，但摊开笔记本有切半页风险，低内容时仍会提示检查',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      RadioGroup<DefaultCropMode>(
                        groupValue: settings.defaultCropMode,
                        onChanged: (value) {
                          if (value != null) {
                            controller.updateSettings(
                              settings.copyWith(defaultCropMode: value),
                            );
                          }
                        },
                        child: Column(
                          children: [
                            for (final mode in DefaultCropMode.values)
                              RadioListTile<DefaultCropMode>(
                                key: Key('settings-crop-${mode.wireName}'),
                                contentPadding: EdgeInsets.zero,
                                value: mode,
                                title: Text(mode.label),
                                subtitle: Text(mode.description),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '设置保存在本机，不会改动已有页面；旧页面仍保留当时的色彩模式和四角。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }

  String _colorLabel(ScanColorMode mode) => switch (mode) {
    ScanColorMode.auto => '自动',
    ScanColorMode.color => '彩色',
    ScanColorMode.grayscale => '灰度',
    ScanColorMode.blackAndWhite => '黑白',
  };
}
