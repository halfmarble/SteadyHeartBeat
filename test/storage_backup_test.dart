import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';
import 'package:steady_heart_beat/services/workout_service.dart';
import 'package:steady_heart_beat/services/tts_service.dart';
import 'package:steady_heart_beat/services/health_profile_store.dart';
import 'package:steady_heart_beat/services/backup_exclusion.dart';

// Exercises the backup-exclusion MECHANISM end to end, with real file I/O in a
// temp directory (path_provider mocked) and the native `excludeFromBackup`
// channel mocked so we can assert it fires. Complements data_privacy_test.dart,
// which proves the prefs-cleanliness invariants without any native mocks.

/// path_provider with no real plugin: point the docs dir at a temp folder.
class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override Future<void> toggle({required bool enable}) async {}
  @override Future<bool> get enabled async => false;
}

class _FakeWorkoutService extends WorkoutService {
  final _hr = StreamController<Map<String, dynamic>>.broadcast();
  final _status = StreamController<Map<String, dynamic>>.broadcast();
  @override Future<bool> requestAuthorization() async => true;
  @override Future<Map<String, dynamic>?> getHealthProfile() async => {'available': false};
  @override Future<Map<String, dynamic>?> getRecentHRV() async => null;
  @override Future<Map<String, dynamic>?> getRestingHR() async => null;
  @override Future<Map<String, dynamic>?> getVO2Max() async => null;
  @override Future<Map<String, dynamic>?> getBodyMass() async => null;
  @override Future<Map<String, dynamic>> checkAirPods() async => {'connected': false, 'name': ''};
  @override Future<void> previewVoice(String identifier, {String? text}) async {}
  @override Future<void> setSaveToHealth(bool enabled) async {}
  @override Stream<Map<String, dynamic>> get heartRateStream => _hr.stream;
  @override Stream<Map<String, dynamic>> get statusStream => _status.stream;
}

class _FakeTts extends TtsService {
  @override Future<void> init() async {}
  @override Future<void> setVoice(String gender) async {}
  @override Future<void> speak(String text, {bool force = false}) async {}
  @override Future<void> stop() async {}
  @override Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _FakeWakelock();

  const channel = MethodChannel('steadyheartbeat/workout');
  late Directory tempDir;
  late List<MethodCall> channelCalls;

  setUp(() {
    // Fresh temp docs dir per test so stores never read each other's files.
    tempDir = Directory.systemTemp.createTempSync('shb_storage_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);

    channelCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      channelCalls.add(call);
      return true; // excludeFromBackup → bool
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  List<MethodCall> exclusionsFor(String path) => channelCalls
      .where((c) => c.method == 'excludeFromBackup' &&
          (c.arguments as Map)['path'] == path)
      .toList();

  group('HealthProfileStore', () {
    test('save → load round-trips the health map', () async {
      final ok = await HealthProfileStore.save({
        'manualAge': 33,
        'healthConditions': ['cardiovascular'],
        'zone5Start': 171,
        'manualHrv': 55.0,
      });
      expect(ok, isTrue);

      final loaded = await HealthProfileStore.load();
      expect(loaded['manualAge'], 33);
      expect(loaded['healthConditions'], ['cardiovascular']);
      expect(loaded['zone5Start'], 171);
      expect((loaded['manualHrv'] as num).toDouble(), 55.0);
    });

    test('writes into a backup-excluded private/ directory', () async {
      await HealthProfileStore.save({'manualAge': 1});
      final privateDir = '${tempDir.path}/private';
      expect(File('$privateDir/health_profile.json').existsSync(), isTrue);
      expect(exclusionsFor(privateDir), hasLength(1),
          reason: 'the private/ dir must be marked excluded from backup');
    });
  });

  group('BackupExclusion', () {
    test('invokes the native channel with the directory path', () async {
      final dir = Directory('${tempDir.path}/alpha');
      await BackupExclusion.ensureExcluded(dir);
      expect(exclusionsFor(dir.path), hasLength(1));
    });

    test('dedupes repeat calls for the same path within a launch', () async {
      final dir = Directory('${tempDir.path}/beta');
      await BackupExclusion.ensureExcluded(dir);
      await BackupExclusion.ensureExcluded(dir);
      await BackupExclusion.ensureExcluded(dir);
      expect(exclusionsFor(dir.path), hasLength(1),
          reason: 'should hit the channel once, then short-circuit');
    });
  });

  group('provider migration — happy path (excluded store available)', () {
    test('legacy prefs are copied into the store and then purged', () async {
      SharedPreferences.setMockInitialValues({
        'manualAge': 40,
        'healthConditions': <String>['cardiovascular'],
        'manualHrv': 55.0,
        'announceInterval': 30, // non-health setting, must survive
      });

      final p = WorkoutProvider(workout: _FakeWorkoutService(), tts: _FakeTts());
      await p.initialized;

      // Health data now lives in the excluded store…
      final stored = await HealthProfileStore.load();
      expect(stored['manualAge'], 40);
      expect(stored['healthConditions'], ['cardiovascular']);
      expect((stored['manualHrv'] as num).toDouble(), 55.0);

      // …and the backed-up prefs copies are gone.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('manualAge'), isFalse);
      expect(prefs.containsKey('healthConditions'), isFalse);
      expect(prefs.containsKey('manualHrv'), isFalse);
      // The non-health app setting is untouched.
      expect(prefs.getInt('announceInterval'), 30);
    });
  });
}
