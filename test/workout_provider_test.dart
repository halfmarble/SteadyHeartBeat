
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';
import 'helpers/fakes.dart';

// ── Fakes ─────────────────────────────────────────────────────────────────────

/// The shared inert service, specialised with the standard zoned profile.
class _FakeWorkoutService extends FakeWorkoutService {
  _FakeWorkoutService() : super(healthProfile: kTestHealthProfile);
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

/// Capturing service that reports no HealthKit profile, so max HR stays null —
/// for the zone-derivation tests.
class _NoHealthProfileWorkoutService extends _CapturingWorkoutService {
  @override
  Future<Map<String, dynamic>?> getHealthProfile() async => {'available': false};
}

/// Reports a resting HR from Apple Health, for the refresh-adopts-Apple-Health test.
class _RestingHrWorkoutService extends _FakeWorkoutService {
  @override
  Future<Map<String, dynamic>?> getRestingHR() async =>
      {'bpm': 62.0, 'timestamp': 1700000000.0};
}

/// Denies HealthKit authorization, for the denied-refresh test.
class _DeniedAuthWorkoutService extends _FakeWorkoutService {
  @override
  Future<bool> requestAuthorization() async => false;
}

/// Returns an overnight-sourced HRV reading (native averages SDNN across the
/// last night's whole in-bed span and tags it source 'bed').
class _BedHrvWorkoutService extends _FakeWorkoutService {
  @override
  Future<Map<String, dynamic>?> getRecentHRV() async =>
      {'ms': 44.0, 'timestamp': 1700000000.0, 'source': 'bed', 'count': 8};
}

/// Returns the single-sample fallback HRV reading (no usable sleep window).
class _RecentHrvWorkoutService extends _FakeWorkoutService {
  @override
  Future<Map<String, dynamic>?> getRecentHRV() async =>
      {'ms': 41.0, 'timestamp': 1700000000.0, 'source': 'recent'};
}

/// Returns an overnight-sourced HR reading (native averages heartRate across
/// the last night's whole in-bed span and tags it source 'bed').
class _BedHrWorkoutService extends _FakeWorkoutService {
  @override
  Future<Map<String, dynamic>?> getRestingHR() async =>
      {'bpm': 58.0, 'timestamp': 1700000000.0, 'source': 'bed', 'count': 40};
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Future<WorkoutProvider> _makeProvider({
  _FakeWorkoutService? workout,
  FakeTtsService? tts,
}) async {
  SharedPreferences.setMockInitialValues({});
  final provider = WorkoutProvider(
    workout: workout ?? _FakeWorkoutService(),
    tts: tts ?? FakeTtsService(),
  );
  // Allow _loadPrefs() async chain to complete
  await Future.delayed(Duration.zero);
  return provider;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = FakeWakelock();

  // ── Delta-announce ─────────────────────────────────────────────────────────

  group('delta announce', () {
    late FakeTtsService tts;
    late WorkoutProvider provider;

    setUp(() async {
      tts = FakeTtsService();
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
  });

  group('unit preference reaches native (ascent cue)', () {
    test('start pushes the imperial flag so the spoken ascent cue matches units',
        () async {
      final fake = _FakeWorkoutService();
      final provider = await _makeProvider(workout: fake);
      provider.setUseImperial(false); // metric
      await provider.start();
      expect(fake.lastUseImperial, false,
          reason: 'native must hear the unit choice so "Climbed N meters/feet" matches');
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

  // ── Refresh adopts Apple Health ──────────────────────────────────────────────

  group('refresh from Apple Health', () {
    test('clears a manual resting HR and adopts the Apple Health value', () async {
      final fake = _RestingHrWorkoutService();
      final provider = await _makeProvider(workout: fake);
      await provider.initialized; // let _loadPrefs finish so it can't clobber the manual set
      provider.setManualRestingHr(58);
      await Future<void>.delayed(Duration.zero);
      expect(provider.manualRestingHr, 58);
      expect(provider.effectiveRestingHrBpm, 58); // manual wins before refresh

      await provider.refreshHealthData();

      expect(provider.manualRestingHr, isNull,
          reason: 'an explicit refresh = adopt Apple Health');
      expect(provider.effectiveRestingHrBpm, 62); // now the Apple Health value
      provider.dispose();
    });

    test('keeps a manual value when Apple Health has nothing to replace it', () async {
      final fake = _FakeWorkoutService(); // all health getters return null
      final provider = await _makeProvider(workout: fake);
      await provider.initialized; // let _loadPrefs finish so it can't clobber the manual set
      provider.setManualVo2Max(48);
      await Future<void>.delayed(Duration.zero);

      await provider.refreshHealthData();

      expect(provider.manualVo2Max, 48,
          reason: 'no Apple Health VO₂ max to adopt — never wipe the only number');
      provider.dispose();
    });
  });

  // ── Overnight (sleep) HRV ────────────────────────────────────────────────────

  group('HRV source', () {
    test('captures the overnight in-bed-averaged reading and its source', () async {
      final provider = await _makeProvider(workout: _BedHrvWorkoutService());
      await provider.initialized;
      // _fetchRecentHRV is launched fire-and-forget at the tail of _loadPrefs;
      // pump the loop so it resolves before asserting.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(provider.recentHrvMs, 44.0);
      expect(provider.hrvSource, 'bed');
      expect(provider.effectiveHrvMs, 44.0);
      provider.dispose();
    });

    test('captures the single-sample fallback source', () async {
      final provider = await _makeProvider(workout: _RecentHrvWorkoutService());
      await provider.initialized;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(provider.recentHrvMs, 41.0);
      expect(provider.hrvSource, 'recent');
      provider.dispose();
    });

    test('captures the overnight in-bed-averaged HR reading and its source', () async {
      final provider = await _makeProvider(workout: _BedHrWorkoutService());
      await provider.initialized;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(provider.recentRestingHrBpm, 58.0);
      expect(provider.restingHrSource, 'bed');
      expect(provider.effectiveRestingHrBpm, 58.0);
      provider.dispose();
    });
  });

  // ── Release hardening (tiers 2–3) ────────────────────────────────────────────

  group('release hardening', () {
    test('HealthKit denied: refresh surfaces an error and keeps the manual value',
        () async {
      final fake = _DeniedAuthWorkoutService();
      final provider = await _makeProvider(workout: fake);
      await provider.initialized;
      provider.setManualVo2Max(48);
      await Future<void>.delayed(Duration.zero);

      await provider.refreshHealthData();

      expect(provider.healthRefreshError, isNotNull,
          reason: 'denied auth → an actionable error, not a silent no-op');
      expect(provider.manualVo2Max, 48,
          reason: 'a denied refresh must not wipe the manual override');
      provider.dispose();
    });

    test('a metric older than 30 days reads as stale (drives the hint)', () async {
      final provider = await _makeProvider();
      await provider.initialized;
      provider.recentVo2MaxMlPerKgMin = 45;
      provider.recentVo2MaxDate = DateTime.now().subtract(const Duration(days: 145));
      expect(provider.vo2Stale, true);
      provider.recentVo2MaxDate = DateTime.now().subtract(const Duration(days: 5));
      expect(provider.vo2Stale, false);
      provider.setManualVo2Max(50); // a manual override is never "stale"
      await Future<void>.delayed(Duration.zero);
      expect(provider.vo2Stale, false);
      provider.dispose();
    });

    test('old-version prefs load cleanly (forward-compat)', () async {
      SharedPreferences.setMockInitialValues({
        'boxingRoundsEnabled': true,
        'roundSecs': 120,
        'announceInterval': 30,
      });
      final provider =
          WorkoutProvider(workout: _FakeWorkoutService(), tts: FakeTtsService());
      await provider.initialized;
      // Pre-existing prefs survive the upgrade. (The Plus module's own
      // missing-key defaults are covered in test/plus/plus_gate_test.dart.)
      expect(provider.boxingRoundsEnabled, true);
      expect(provider.roundSecs, 120);
      provider.dispose();
    });
  });

  // ── Zone / max-HR derivation (load-bearing math) ─────────────────────────────

  group('zone / max-HR derivation', () {
    test('age derives max HR, the five zones, and the danger threshold', () async {
      // No-profile fake so the HealthKit DOB can't override the manual age.
      final provider = await _makeProvider(workout: _NoHealthProfileWorkoutService());
      await provider.initialized;
      await provider.setManualAge(50);
      expect(provider.maxHeartRate, 173); // round(208 − 0.7·50)
      expect(provider.zone1End, 87); //  50%
      expect(provider.zone2Start, 104); // 60%
      expect(provider.zone3Start, 121); // 70%
      expect(provider.zone4Start, 138); // 80%
      expect(provider.zone5Start, 156); // 90%
      expect(provider.dangerZoneThreshold, 156); // = zone5Start (90%)
      provider.dispose();
    });

    test('no age → null zones and the default danger fallback (175)', () async {
      final provider = await _makeProvider(workout: _NoHealthProfileWorkoutService());
      await provider.initialized;
      await provider.setManualAge(null); // re-fetch finds no DOB → stays cleared
      expect(provider.maxHeartRate, isNull);
      expect(provider.zone1End, isNull);
      expect(provider.zone5Start, isNull);
      expect(provider.dangerZoneThreshold, 175); // kDefaultDangerBpm
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
