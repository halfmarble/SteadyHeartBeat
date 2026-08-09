import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'helpers/fakes.dart';
import 'package:steady_heart_beat/services/export_service.dart';

// The share flow writes a PLAINTEXT copy of the health export to the tmp dir
// for the share sheet. That copy must not outlive the share — tmp is outside
// the backup-excluded protected stores, and a lingering cleartext bundle
// there would quietly defeat the point of protecting the real ones.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('shb_export_cleanup_');
    PathProviderPlatform.instance = FakePathProvider(tempDir.path);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the temp file exists for the share and is deleted afterwards',
      () async {
    String? sharedPath;
    String? contentAtShareTime;
    ExportService.sharePresenter = (file, subject, origin) async {
      sharedPath = file.path;
      contentAtShareTime = await File(file.path).readAsString();
    };

    final err = await ExportService.shareJsonFile('{"k":"v"}', 'bundle.json');
    expect(err, isNull);
    expect(sharedPath, isNotNull);
    expect(contentAtShareTime, '{"k":"v"}',
        reason: 'the presenter must see the full payload on disk');
    expect(File(sharedPath!).existsSync(), isFalse,
        reason: 'the plaintext copy must be deleted once the share returns');
  });

  test('the temp file is deleted even when the share throws', () async {
    String? sharedPath;
    ExportService.sharePresenter = (file, subject, origin) async {
      sharedPath = file.path;
      throw StateError('no share sheet in tests');
    };

    final err = await ExportService.shareJsonFile('{"k":"v"}', 'bundle.json');
    expect(err, isNotNull); // step-tagged error string
    expect(err, contains('share'));
    expect(File(sharedPath!).existsSync(), isFalse,
        reason: 'cleanup must run on the failure path too');
  });
}
