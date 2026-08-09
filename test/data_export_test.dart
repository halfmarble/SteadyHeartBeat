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
import 'package:steady_heart_beat/services/export_service.dart';
import 'package:steady_heart_beat/services/health_profile_store.dart';
import 'package:steady_heart_beat/services/session_storage_service.dart';

// Covers the data-portability features: the owner can take a complete copy of
// their data off-device (export bundle) and erase everything stored on-device
// (delete-all). Real file I/O in a temp dir; the share sheet itself is native
// and out of scope here — we test the bundle assembly and the deletion, which
// is the logic this app owns.

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

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('shb_export_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    // The file-backed stores mark their dir excluded-from-backup via this channel.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('ExportService.buildBundle', () {
    test('bundles the health profile and every session with an envelope', () async {
      await HealthProfileStore.save({'manualAge': 44, 'manualHrv': 60.0});
      await SessionStorageService.save({'id': '2026-06-01T10:00:00.000', 'avgBpm': 120});
      await SessionStorageService.save({'id': '2026-06-02T10:00:00.000', 'avgBpm': 135});

      final bundle = await ExportService.buildBundle(
          now: DateTime.utc(2026, 6, 9, 12));

      expect(bundle['schemaVersion'], ExportService.schemaVersion);
      expect(bundle['generatedBy'], 'SteadyHeartBeat');
      expect(bundle['exportedAt'], '2026-06-09T12:00:00.000Z');
      expect(bundle['healthProfile'], {'manualAge': 44, 'manualHrv': 60.0});
      expect(bundle['sessionCount'], 2);
      final sessions = (bundle['sessions'] as List).cast<Map<String, dynamic>>();
      expect(sessions.map((s) => s['id']), containsAll([
        '2026-06-01T10:00:00.000',
        '2026-06-02T10:00:00.000',
      ]));
    });

    test('is well-formed even with no data yet', () async {
      final bundle = await ExportService.buildBundle(now: DateTime.utc(2026));
      expect(bundle['sessionCount'], 0);
      expect(bundle['sessions'], isEmpty);
      expect(bundle['healthProfile'], isEmpty);
    });
  });

  group('SessionStorageService.deleteAll', () {
    test('removes every session and returns the count', () async {
      await SessionStorageService.save({'id': '2026-06-01T10:00:00.000'});
      await SessionStorageService.save({'id': '2026-06-02T10:00:00.000'});
      await SessionStorageService.saveInProgress({'id': 'live'});

      final removed = await SessionStorageService.deleteAll();

      expect(removed, 2, reason: 'in-progress snapshot is not counted');
      expect(await SessionStorageService.count(), 0);
      expect(await SessionStorageService.loadAll(), isEmpty);
      expect(await SessionStorageService.loadInProgress(), isNull);
    });
  });

  group('HealthProfileStore.clear', () {
    test('deletes the stored profile', () async {
      await HealthProfileStore.save({'manualAge': 50});
      expect(await HealthProfileStore.load(), isNotEmpty);
      await HealthProfileStore.clear();
      expect(await HealthProfileStore.load(), isEmpty);
    });
  });

  group('WorkoutProvider.clearAllData', () {
    test('wipes stored data and resets in-memory health state, keeps settings', () async {
      SharedPreferences.setMockInitialValues({'announceInterval': 30});
      final p = WorkoutProvider(workout: _FakeWorkoutService(), tts: _FakeTts());
      await p.initialized;

      await p.setManualAge(42);
      await p.setManualHrv(55);
      await SessionStorageService.save({'id': '2026-06-01T10:00:00.000'});
      await Future.delayed(Duration.zero);

      final removed = await p.clearAllData();

      expect(removed, 1);
      // Stored data is gone.
      expect(await SessionStorageService.count(), 0);
      expect(await HealthProfileStore.load(), isEmpty);
      // In-memory health state is reset to first-launch defaults.
      expect(p.manualAge, isNull);
      expect(p.manualHrvMs, isNull);
      expect(p.maxHeartRate, isNull);
      expect(p.zone5Start, isNull);
      // Non-health app settings survive.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('announceInterval'), 30);
    });
  });
}
