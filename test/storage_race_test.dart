import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:steady_heart_beat/services/session_storage_service.dart';

// The in-progress snapshot write/delete race: a throttled fire-and-forget
// saveInProgress still in flight when the final save calls clearInProgress
// used to land AFTER the delete, resurrecting in_progress.json — which the
// next launch then "recovered" as a duplicate session. The service now chains
// writes and clearInProgress awaits the tail of the chain.

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('shb_storage_race_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File inProgressFile() => File('${tempDir.path}/sessions/in_progress.json');

  Map<String, dynamic> snapshot(int n) => {
        'id': 'snap-$n',
        'hrTimeline': [
          for (var i = 0; i < n; i++) [i.toDouble(), 100.0 + i]
        ],
      };

  test('clearInProgress wins over an un-awaited snapshot write in flight',
      () async {
    // Fire-and-forget, exactly like the provider's throttled snapshot path.
    final pending = SessionStorageService.saveInProgress(snapshot(50));
    // Immediately clear (the final-save path) WITHOUT awaiting the write.
    await SessionStorageService.clearInProgress();
    await pending;

    expect(inProgressFile().existsSync(), isFalse,
        reason: 'a pending snapshot must not resurrect the recovery file');
    expect(await SessionStorageService.loadInProgress(), isNull);
  });

  test('a burst of un-awaited writes then clear still ends deleted', () async {
    for (var i = 0; i < 5; i++) {
      SessionStorageService.saveInProgress(snapshot(i + 2));
    }
    await SessionStorageService.clearInProgress();
    // Give any stray write every chance to (incorrectly) land afterwards.
    await Future.delayed(const Duration(milliseconds: 30));

    expect(inProgressFile().existsSync(), isFalse);
  });

  test('writes still land when not followed by a clear', () async {
    await SessionStorageService.saveInProgress(snapshot(3));
    final loaded = await SessionStorageService.loadInProgress();
    expect(loaded, isNotNull);
    expect((loaded!['hrTimeline'] as List).length, 3);
    await SessionStorageService.clearInProgress();
  });
}
