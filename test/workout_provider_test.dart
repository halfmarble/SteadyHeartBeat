import 'dart:async';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';
import 'package:steady_heart_beat/services/workout_service.dart';
import 'package:steady_heart_beat/services/tts_service.dart';

// ── Fakes ─────────────────────────────────────────────────────────────────────

class _FakeWorkoutService extends WorkoutService {
  final _hrCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _statusCtrl = StreamController<Map<String, dynamic>>.broadcast();

  void pushHR(double bpm) => _hrCtrl.add({'bpm': bpm});
  void pushStatus(Map<String, dynamic> event) => _statusCtrl.add(event);
  Future<void> closeStreams() async {
    await _hrCtrl.close();
    await _statusCtrl.close();
  }

  @override Future<bool> requestAuthorization() async => true;
  @override Future<bool> startWorkout({String workoutType = 'other', int announceIntervalSeconds = 15}) async => true;
  @override Future<void> stopWorkout() async {}
  @override Future<void> setAnnounceInterval(int seconds) async {}
  @override Future<void> setSaveToHealth(bool enabled) async {}
  @override Future<Map<String, dynamic>> checkAirPods() async =>
      {'connected': true, 'activeOnThisDevice': true, 'name': 'Test AirPods'};
  @override Future<bool> bindAirPods() async => true;
  @override Future<Map<String, dynamic>?> getHealthProfile() async => {
    'available': true, 'age': 40, 'maxHeartRate': 180,
    'zone1End': 90, 'zone2Start': 108, 'zone3Start': 126,
    'zone4Start': 144, 'zone5Start': 162,
  };
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

/// No-op wakelock so `_setError` / start paths that toggle the screen lock
/// don't hit the (unmocked) platform channel under test.
class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

/// A workout service whose native startWorkout throws (as the real channel
/// does when AppDelegate returns a FlutterError) instead of returning false.
class _ThrowingWorkoutService extends _FakeWorkoutService {
  @override
  Future<bool> startWorkout(
          {String workoutType = 'other', int announceIntervalSeconds = 15}) async =>
      throw PlatformException(code: 'START_ERROR', message: 'boom');
}

/// Captures the boxing config pushed to native so the start path can be asserted.
class _CapturingWorkoutService extends _FakeWorkoutService {
  Map<String, dynamic>? lastBoxingConfig;
  @override
  Future<void> setBoxingRounds(
      {required bool enabled,
      required int roundSecs,
      required int restSecs,
      required int totalRounds,
      required int warnSecs,
      required int prepSecs}) async {
    lastBoxingConfig = {
      'enabled': enabled,
      'roundSecs': roundSecs,
      'restSecs': restSecs,
      'totalRounds': totalRounds,
      'warnSecs': warnSecs,
      'prepSecs': prepSecs,
    };
  }
}

class _FakeTtsService extends TtsService {
  final List<String> spoken = [];
  @override Future<void> init() async {}
  @override Future<void> setVoice(String gender) async {}
  @override Future<void> speak(String text) async => spoken.add(text);
  @override Future<void> stop() async {}
  @override Future<void> dispose() async {}
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Future<WorkoutProvider> _makeProvider({
  _FakeWorkoutService? workout,
  _FakeTtsService? tts,
}) async {
  SharedPreferences.setMockInitialValues({});
  final provider = WorkoutProvider(
    workout: workout ?? _FakeWorkoutService(),
    tts: tts ?? _FakeTtsService(),
  );
  // Allow _loadPrefs() async chain to complete
  await Future.delayed(Duration.zero);
  return provider;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _FakeWakelock();

  // ── Delta-announce ─────────────────────────────────────────────────────────

  group('delta announce', () {
    late _FakeTtsService tts;
    late WorkoutProvider provider;

    setUp(() async {
      tts = _FakeTtsService();
      provider = await _makeProvider(tts: tts);
      // Announce-on-change is off by default now; this group tests the delta
      // path, so opt in explicitly. (The "delta disabled" case below turns it
      // back off itself.)
      provider.setDeltaAnnounceEnabled(true);
      provider.setRunningForTest();
    });

    tearDown(() => provider.dispose());

    test('first HR sample always announces (no baseline yet)', () {
      provider.simulateHeartRateForTest(120);
      expect(tts.spoken, contains('120'));
    });

    test('change below threshold does NOT announce', () {
      provider.simulateHeartRateForTest(120);
      final countAfterFirst = tts.spoken.length;
      // Default deltaThreshold is 10 — change of 5 should be silent
      provider.simulateHeartRateForTest(125);
      expect(tts.spoken.length, countAfterFirst); // no new utterance
    });

    test('change at threshold announces', () {
      provider.simulateHeartRateForTest(120);
      final countAfterFirst = tts.spoken.length;
      provider.simulateHeartRateForTest(130); // exactly +10
      expect(tts.spoken.length, greaterThan(countAfterFirst));
      expect(tts.spoken.last, '130');
    });

    test('change above threshold announces', () {
      provider.simulateHeartRateForTest(120);
      final countAfterFirst = tts.spoken.length;
      provider.simulateHeartRateForTest(145); // +25
      expect(tts.spoken.length, greaterThan(countAfterFirst));
      expect(tts.spoken.last, '145');
    });

    test('delta fires for drop, not just rise', () {
      provider.simulateHeartRateForTest(150);
      final countAfterFirst = tts.spoken.length;
      provider.simulateHeartRateForTest(138); // -12
      expect(tts.spoken.length, greaterThan(countAfterFirst));
    });

    test('baseline resets after delta fires, suppressing the next small move', () {
      provider.simulateHeartRateForTest(120); // sets baseline=120
      provider.simulateHeartRateForTest(132); // delta fires → baseline=132
      final count = tts.spoken.length;
      provider.simulateHeartRateForTest(137); // only +5 from new baseline → silent
      expect(tts.spoken.length, count);
    });

    test('interval announce resets baseline', () {
      provider.simulateHeartRateForTest(120);
      // Simulate the periodic timer firing
      provider.triggerIntervalAnnounceForTest();
      expect(provider.deltaBpmBaselineForTest, 120);
    });

    test('delta disabled — no delta fires regardless of change', () {
      provider.setDeltaAnnounceEnabled(false);
      provider.simulateHeartRateForTest(120);
      final count = tts.spoken.length;
      provider.simulateHeartRateForTest(160); // +40 but delta disabled
      expect(tts.spoken.length, count);
    });
  });

  // ── Start error handling ────────────────────────────────────────────────────

  group('start error handling', () {
    test('platform error during start surfaces an error state, not a stuck spinner',
        () async {
      final provider =
          await _makeProvider(workout: _ThrowingWorkoutService());
      await provider.start();
      // The thrown PlatformException must be caught and routed to the error UI
      // rather than leaving state pinned at `starting`.
      expect(provider.state, MonitoringState.error);
      expect(provider.errorMessage, isNotNull);
      provider.dispose();
    });
  });

  // ── Boxing round timer ──────────────────────────────────────────────────────

  group('boxing round timer', () {
    test('start pushes round config to native (warning off → warnSecs 0)',
        () async {
      final fake = _CapturingWorkoutService();
      final provider = await _makeProvider(workout: fake);
      provider.setWorkoutType(WorkoutType.boxing);
      provider.setBoxingRoundsEnabled(true);
      provider.setRoundSecs(120);
      provider.setRestSecs(45);
      provider.setTotalRounds(8);
      provider.setRoundWarnEnabled(false);
      await provider.start();
      final cfg = fake.lastBoxingConfig;
      expect(cfg, isNotNull);
      expect(cfg!['enabled'], true);
      expect(cfg['roundSecs'], 120);
      expect(cfg['restSecs'], 45);
      expect(cfg['totalRounds'], 8);
      expect(cfg['warnSecs'], 0);
      provider.dispose();
    });

    test('round status event updates live fields', () async {
      final fake = _FakeWorkoutService();
      final provider = await _makeProvider(workout: fake);
      await provider.start();
      fake.pushStatus({
        'type': 'round',
        'phase': 'work',
        'round': 2,
        'total': 12,
        'remaining': 128,
      });
      await Future.delayed(Duration.zero);
      expect(provider.roundPhase, 'work');
      expect(provider.currentRound, 2);
      expect(provider.roundTotal, 12);
      expect(provider.roundRemaining, 128);
      provider.dispose();
    });
  });

  // ── BPM smoothing ──────────────────────────────────────────────────────────

  group('BPM smoothing', () {
    late WorkoutProvider provider;

    setUp(() async {
      provider = await _makeProvider();
      provider.setRunningForTest();
    });

    tearDown(() => provider.dispose());

    test('smoothed list grows with bpmHistory', () {
      provider.addBpmSampleForTest(0, 100);
      provider.addBpmSampleForTest(1, 110);
      provider.addBpmSampleForTest(2, 120);
      expect(provider.smoothedBpms.length, 3);
    });

    test('single sample: smoothed equals raw', () {
      provider.addBpmSampleForTest(0, 100);
      expect(provider.smoothedBpms.first, closeTo(100, 0.01));
    });

    test('window averages reduce spike amplitude', () {
      // Inject a spike at position 2, surrounded by steady values
      for (int i = 0; i < 5; i++) {
        provider.addBpmSampleForTest(i.toDouble(), i == 2 ? 160 : 100);
      }
      // The smoothed value at the spike should be less than the raw 160
      expect(provider.smoothedBpms[2], lessThan(160));
      expect(provider.smoothedBpms[2], greaterThan(100));
    });
  });

  // ── Zone time computation ──────────────────────────────────────────────────

  group('zone time', () {
    late WorkoutProvider provider;

    setUp(() async {
      provider = await _makeProvider();
      provider.setRunningForTest();
      // Inject the zone boundaries (age-40 zones: max 180 bpm)
      provider.zone1End   = 90;
      provider.zone2Start = 108;
      provider.zone3Start = 126;
      provider.zone4Start = 144;
      provider.zone5Start = 162;
      provider.maxHeartRate = 180;
    });

    tearDown(() => provider.dispose());

    test('all samples in zone 1 → all time in zone 1', () {
      // Zone index 1: [brady(50), zone1End(90)) → use 70 bpm (for maxHR=180)
      provider.addBpmSampleForTest(0, 70);
      provider.addBpmSampleForTest(60, 70); // 60 s at 70 bpm
      provider.computeSummaryForTest();

      final zones = provider.summaryZoneSecs!;
      expect(zones[1], closeTo(60, 0.5));
      expect(zones[0] + zones[2] + zones[3] + zones[4] + zones[5], closeTo(0, 0.5));
    });

    test('mixed zones distribute time correctly', () {
      // Zone index 2: [90, 108) → 95 bpm; Zone index 4: [126, 144) → 130 bpm.
      // Duplicate timestamp at t=30 creates a zero-duration trapezoidal segment,
      // preventing zone-crossing contamination in the transition.
      provider.addBpmSampleForTest(0, 95);
      provider.addBpmSampleForTest(30, 95);   // 30 s at zone 2
      provider.addBpmSampleForTest(30, 130);  // dt=0 transition (no contribution)
      provider.addBpmSampleForTest(60, 130);  // 30 s at zone 4
      provider.computeSummaryForTest();

      final zones = provider.summaryZoneSecs!;
      expect(zones[2], closeTo(30, 1)); // zone 2
      expect(zones[4], closeTo(30, 1)); // zone 4
    });

    test('bradycardia BPM goes into zone index 0', () {
      // <50 bpm = bradycardia
      provider.addBpmSampleForTest(0, 40);
      provider.addBpmSampleForTest(60, 40);
      provider.computeSummaryForTest();

      expect(provider.summaryZoneSecs![0], closeTo(60, 0.5));
    });

    test('summaryZoneSecs has exactly 6 elements', () {
      provider.addBpmSampleForTest(0, 100);
      provider.addBpmSampleForTest(10, 100);
      provider.computeSummaryForTest();
      expect(provider.summaryZoneSecs!.length, 6);
    });

    test('total zone time equals session duration', () {
      provider.addBpmSampleForTest(0, 120);
      provider.addBpmSampleForTest(120, 150); // 2-minute session
      provider.computeSummaryForTest();

      final total = provider.summaryZoneSecs!.reduce((a, b) => a + b);
      expect(total, closeTo(120, 1));
    });
  });

  // ── Summary statistics ─────────────────────────────────────────────────────

  group('summary statistics', () {
    late WorkoutProvider provider;

    setUp(() async {
      provider = await _makeProvider();
      provider.setRunningForTest();
    });

    tearDown(() => provider.dispose());

    test('max and min BPM are correct', () {
      provider.addBpmSampleForTest(0, 100);
      provider.addBpmSampleForTest(10, 140);
      provider.addBpmSampleForTest(20, 120);
      provider.computeSummaryForTest();

      expect(provider.summaryMaxBpm, 140);
      expect(provider.summaryMinBpm, 100);
    });

    test('time-weighted average is correct for constant BPM', () {
      provider.addBpmSampleForTest(0, 130);
      provider.addBpmSampleForTest(60, 130);
      provider.computeSummaryForTest();

      expect(provider.summaryAvgBpm, closeTo(130, 0.1));
    });

    test('state transitions to stopped after computeSummaryForTest', () {
      provider.addBpmSampleForTest(0, 100);
      provider.addBpmSampleForTest(10, 100);
      provider.computeSummaryForTest();
      expect(provider.state, MonitoringState.stopped);
    });
  });
}
