import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';
import 'package:steady_heart_beat/services/workout_service.dart';
import 'package:steady_heart_beat/services/tts_service.dart';

// These tests pin the privacy invariants we hardened: personal health data must
// never be written to shared_preferences (NSUserDefaults → included in
// iCloud/iTunes backups), the save-to-Apple-Health choice must be honoured and
// pushed to native, and the app must not gain a dependency capable of sending
// data off-device.
//
// NOTE: the file-backed stores (HealthProfileStore / SessionStorageService)
// can't write in the unit-test environment — path_provider has no native
// implementation here, so their writes log-and-no-op. That's fine: every
// assertion below is about what does (not) reach shared_preferences and the
// native channel, neither of which depends on those files succeeding.

/// Every shared_preferences key that holds personal health data. None of these
/// may ever appear in the (backed-up) prefs store — they belong in the
/// backup-excluded HealthProfileStore instead. Kept as an explicit literal so
/// the test fails loudly if a new health key is introduced.
const _healthPrefKeys = [
  'manualAge', 'manualSex', 'healthSex', 'healthConditions',
  'manualHrv', 'manualVo2Max', 'manualRestingHr', 'manualWeight',
  'healthAge', 'maxHeartRate',
  'zone1End', 'zone2Start', 'zone3Start', 'zone4Start', 'zone5Start',
  'dangerZoneThreshold',
];

/// Captures values pushed to the native layer so we can assert the privacy
/// wiring without a real platform channel.
class _CapturingWorkoutService extends WorkoutService {
  final _hrCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _statusCtrl = StreamController<Map<String, dynamic>>.broadcast();

  bool? lastSaveToHealth;
  int saveToHealthCalls = 0;

  @override Future<void> setSaveToHealth(bool enabled) async {
    lastSaveToHealth = enabled;
    saveToHealthCalls++;
  }

  @override Future<bool> requestAuthorization() async => true;
  @override Future<bool> startWorkout({String workoutType = 'other', int announceIntervalSeconds = 15}) async => true;
  @override Future<void> stopWorkout() async {}
  @override Future<void> setAnnounceInterval(int seconds) async {}
  @override Future<void> setUseImperial(bool imperial) async {}
  @override Future<Map<String, dynamic>> checkAirPods() async =>
      {'connected': true, 'activeOnThisDevice': true, 'name': 'Test AirPods'};
  @override Future<bool> bindAirPods() async => true;
  @override Future<Map<String, dynamic>?> getHealthProfile() async => {'available': false};
  @override Future<Map<String, dynamic>?> getRecentHRV() async => null;
  @override Future<Map<String, dynamic>?> getRestingHR() async => null;
  @override Future<Map<String, dynamic>?> getVO2Max() async => null;
  @override Future<Map<String, dynamic>?> getBodyMass() async => null;
  @override Future<List<Map<String, dynamic>>> listVoices() async => const [];
  @override Future<String> currentVoiceIdentifier() async => '';
  @override Future<void> previewVoice(String identifier, {String? text}) async {}
  @override Future<void> setZones(List<int> bounds) async {}
  @override Future<void> setZoneCoaching({required bool enabled, required int targetZone}) async {}
  @override Future<void> setBoxingRounds({required bool enabled, required int roundSecs, required int restSecs, required int totalRounds, required int warnSecs, required int prepSecs}) async {}
  @override Stream<Map<String, dynamic>> get heartRateStream => _hrCtrl.stream;
  @override Stream<Map<String, dynamic>> get statusStream => _statusCtrl.stream;
}

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override Future<void> toggle({required bool enable}) async {}
  @override Future<bool> get enabled async => false;
}

class _FakeTts extends TtsService {
  @override Future<void> init() async {}
  @override Future<void> setVoice(String gender) async {}
  @override Future<void> speak(String text, {bool force = false}) async {}
  @override Future<void> stop() async {}
  @override Future<void> dispose() async {}
}

Future<WorkoutProvider> _makeProvider(_CapturingWorkoutService workout) async {
  final p = WorkoutProvider(workout: workout, tts: _FakeTts());
  await p.initialized; // deterministic: load + migration complete
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _FakeWakelock();

  group('health data never reaches shared_preferences (the backed-up store)', () {
    test('no health key is written when the user edits every health field', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await _makeProvider(_CapturingWorkoutService());

      await p.setManualAge(42);          // also derives + would-persist zones
      await p.setManualSex('female');
      p.setHealthConditions({'cardiovascular', 'parkinsons'});
      await p.setManualHrv(55);
      await p.setManualVo2Max(48);
      await p.setManualRestingHr(52);
      await p.setManualWeight(80);
      await Future.delayed(Duration.zero); // let fire-and-forget saves settle

      final prefs = await SharedPreferences.getInstance();
      for (final k in _healthPrefKeys) {
        expect(prefs.containsKey(k), isFalse,
            reason: '"$k" is health data and must not be in backed-up prefs');
      }
    });

    test('toggling a non-health app setting still never adds a health key', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await _makeProvider(_CapturingWorkoutService());
      p.setUseImperial(false);
      await Future.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      for (final k in _healthPrefKeys) {
        expect(prefs.containsKey(k), isFalse, reason: '"$k" leaked via savePrefs');
      }
      expect(prefs.containsKey('useImperial'), isTrue); // app settings still persist
    });
  });

  group('migration is loss-safe when the excluded store is unavailable', () {
    // In this environment path_provider has no implementation, so the excluded
    // store write fails — the hardened migration must then KEEP the legacy
    // prefs rather than dropping the user's only copy. (The happy-path purge,
    // where the store works, is covered in storage_backup_test.dart.)
    test('legacy values still load, and are retained rather than lost', () async {
      SharedPreferences.setMockInitialValues({
        'manualAge': 40,
        'healthConditions': <String>['cardiovascular'],
        'manualHrv': 55.0,
      });
      final p = await _makeProvider(_CapturingWorkoutService());

      // Loaded into memory via the fallback read…
      expect(p.manualAge, 40);
      expect(p.healthConditions, {'cardiovascular'});
      expect(p.manualHrvMs, 55.0);

      // …and NOT stripped, since the excluded store couldn't accept them.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('manualAge'), 40, reason: 'must not lose data on store failure');
      expect(prefs.getStringList('healthConditions'), ['cardiovascular']);
    });
  });

  group('save-to-Apple-Health is opt-out and honoured', () {
    test('defaults to on', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await _makeProvider(_CapturingWorkoutService());
      expect(p.saveToHealth, isTrue);
    });

    test('toggle persists and is pushed to native', () async {
      SharedPreferences.setMockInitialValues({});
      final w = _CapturingWorkoutService();
      final p = await _makeProvider(w);

      p.setSaveToHealth(false);
      await Future.delayed(Duration.zero);

      expect(p.saveToHealth, isFalse);
      expect(w.lastSaveToHealth, isFalse); // told the native layer to discard
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('saveToHealth'), isFalse);
    });

    test('persisted "off" is restored on the next launch', () async {
      SharedPreferences.setMockInitialValues({'saveToHealth': false});
      final p = await _makeProvider(_CapturingWorkoutService());
      expect(p.saveToHealth, isFalse);
    });

    test('the choice is pushed to native at workout start', () async {
      SharedPreferences.setMockInitialValues({'saveToHealth': false});
      final w = _CapturingWorkoutService();
      final p = await _makeProvider(w);
      w.lastSaveToHealth = null; // ignore anything from construction

      await p.start();

      expect(w.lastSaveToHealth, isFalse,
          reason: 'start() must re-push the flag so a fresh native singleton discards');
    });
  });

  group('dependency canary — nothing that can send data off-device', () {
    test('pubspec runtime dependencies stay within the vetted allowlist', () {
      // Every runtime dependency is local/offline. If a new one is added, this
      // fails on purpose: confirm it cannot exfiltrate data, then add it here.
      const allowed = {
        'flutter', 'cupertino_icons', 'shared_preferences', 'provider',
        'fl_chart', 'path_provider', 'wakelock_plus', 'url_launcher',
        // share_plus: presents the OS share sheet for the user-initiated data
        // export. Vetted local-only — it invokes UIActivityViewController and
        // has no network access of its own. See DATA_PORTABILITY.md.
        'share_plus',
      };

      final lines = File('pubspec.yaml').readAsLinesSync();
      final deps = <String>{};
      var inDeps = false;
      for (final line in lines) {
        if (line.startsWith('dependencies:')) { inDeps = true; continue; }
        if (inDeps && line.isNotEmpty && !line.startsWith(' ')) break; // next top-level block
        final m = RegExp(r'^  (\w[\w-]*):').firstMatch(line);
        if (inDeps && m != null) deps.add(m.group(1)!);
      }

      expect(deps, isNotEmpty, reason: 'failed to parse dependencies from pubspec.yaml');
      final unexpected = deps.difference(allowed);
      expect(unexpected, isEmpty,
          reason: 'New runtime dependency $unexpected — verify it cannot send '
              'data off-device, then add it to the allowlist.');
    });
  });
}
