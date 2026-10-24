import 'package:share_plus/share_plus.dart';

import 'pdf_export_service.dart';

typedef PdfShareCallback = Future<void> Function(PdfExportResult result);

/// Opens the Android system share sheet with the generated PDF. The sheet is
/// also the route to "Save to Files"/Drive, so no extra storage permission is
/// needed and the user can rename the file in the receiving app.
Future<void> sharePdf(PdfExportResult result) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile(
          result.path,
          mimeType: 'application/pdf',
          name: result.path.split(RegExp(r'[/\\]')).last,
        ),
      ],
      subject: '作业扫描 PDF',
      text: '作业扫描导出（${result.pageCount} 页）',
    ),
  );
}
