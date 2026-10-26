import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homework_scanner/services/gallery_save_service.dart';

/// Phase 1: the gallery channel must receive the *processed* file with an
/// extension and MIME type that match what is really on disk.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('homework_scanner/gallery');
  final service = GallerySaveService();
  final calls = <MethodCall>[];
  Object? reply;

  setUp(() {
    calls.clear();
    reply = <String, Object?>{
      'ok': true,
      'savedPath': 'Pictures/作业扫描/作业扫描_20260101_101500_第1页.jpg',
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return reply;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('把处理结果路径和真实扩展名交给原生', () async {
    const processed =
        '/data/user/0/org.homeworkscanner.homework_scanner/app_flutter/'
        'doc_1/processed/page_abc_9.jpg';
    final result = await service.saveImage(
      processed,
      fileName: '作业扫描_20260101_101500_第1页.jpg',
    );

    expect(result.ok, isTrue);
    expect(result.savedPath, contains('Pictures/作业扫描/'));
    expect(calls, hasLength(1));
    expect(calls.single.method, 'saveImage');
    final args = calls.single.arguments! as Map<Object?, Object?>;
    expect(args['path'], processed);
    expect(args['fileName'], '作业扫描_20260101_101500_第1页.jpg');
  });

  test('黑白页 PNG 的扩展名与 MIME 保持一致', () {
    expect(GallerySaveService.extensionFor('/x/page_9.png'), '.png');
    expect(GallerySaveService.mimeTypeFor('/x/page_9.png'), 'image/png');
    expect(GallerySaveService.extensionFor('/x/page_9.jpeg'), '.jpg');
    expect(GallerySaveService.mimeTypeFor('/x/page_9.jpeg'), 'image/jpeg');
    expect(GallerySaveService.extensionFor('/x/page_9.gif'), isNull);
    expect(GallerySaveService.mimeTypeFor('/x/page_9.gif'), isNull);
  });

  test('文件名格式为 作业扫描_yyyyMMdd_HHmmss_第N页.扩展名', () {
    expect(
      GallerySaveService.fileNameFor(
        '/tmp/page_1.png',
        3,
        now: DateTime(2026, 1, 2, 8, 9, 10),
      ),
      '作业扫描_20260102_080910_第3页.png',
    );
    expect(
      GallerySaveService.fileNameFor(
        '/tmp/page_1.jpg',
        12,
        now: DateTime(2026, 11, 30, 23, 59, 59),
      ),
      '作业扫描_20261130_235959_第12页.jpg',
    );
  });

  test('原生返回 share_fallback 时标记为改走系统分享', () async {
    reply = <String, Object?>{'ok': false, 'code': 'share_fallback'};
    final result = await service.saveImage(
      '/tmp/page_1.jpg',
      fileName: 'a.jpg',
    );

    expect(result.ok, isFalse);
    expect(result.needsShareSheet, isTrue);
    expect(result.savedPath, isNull);
  });

  test('原生 PlatformException 转成失败结果并带上原因', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'write_failed', message: '磁盘已满');
        });
    final result = await service.saveImage(
      '/tmp/page_1.jpg',
      fileName: 'a.jpg',
    );

    expect(result.ok, isFalse);
    expect(result.needsShareSheet, isFalse);
    expect(result.code, 'write_failed');
    expect(result.message, contains('磁盘已满'));
  });

  test('原生返回非结构化结果时报错而不是崩溃', () async {
    reply = 'not-a-map';
    final result = await service.saveImage(
      '/tmp/page_1.jpg',
      fileName: 'a.jpg',
    );

    expect(result.ok, isFalse);
    expect(result.code, 'bad_response');
  });
}
