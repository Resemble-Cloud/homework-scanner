import 'dart:async';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'features/document/document_screen.dart';
import 'services/document_controller.dart';
import 'services/pdf_export_service.dart';
import 'services/session_store.dart';
import 'services/share_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final root = await getApplicationDocumentsDirectory();
  final store = SessionStore(root: root);
  final controller = DocumentController(
    engine: FairScanEngine(),
    store: store,
    exporter: const PdfExportService(),
  );
  await controller.initialize();
  runApp(HomeworkScannerApp(controller: controller));
}

class HomeworkScannerApp extends StatelessWidget {
  const HomeworkScannerApp({
    super.key,
    required this.controller,
    this.pickImage,
    this.sharePdfCallback,
  });

  final DocumentController controller;
  final Future<String?> Function()? pickImage;
  final PdfShareCallback? sharePdfCallback;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '作业扫描',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E6F5E),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F8F6),
      ),
      home: DocumentScreen(
        controller: controller,
        pickImage: pickImage,
        sharePdfCallback: sharePdfCallback,
      ),
    );
  }
}
