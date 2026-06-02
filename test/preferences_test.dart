// Tests for workout type preference persistence in WorkoutProvider.
//
// These tests pin the requirement that selectedWorkoutType survives app
// restarts (SharedPreferences round-trip).  Run them before and after
// the persistence fix to confirm the fix is correct and complete.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';
import 'announcement_test.dart'; // reuse FakeTtsService / FakeWorkoutService

// ── Helpers ───────────────────────────────────────────────────────────────────

// Drain the microtask + event queue — needed because savePrefs() has 8 awaits
// and is called fire-and-forget from setWorkoutType().
Future<void> drain() async {
  for (int i = 0; i < 15; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<WorkoutProvider> makeProvider({String? storedWorkoutType}) async {
  SharedPreferences.setMockInitialValues(
    storedWorkoutType != null ? {'workoutType': storedWorkoutType} : {},
  );
  final p = WorkoutProvider(
    tts: FakeTtsService(),
    workout: FakeWorkoutService(),
  );
  await drain(); // wait for _loadPrefs and any initial fetches
  return p;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── 1. Default value ──────────────────────────────────────────────────────

  group('workout type — default', () {
    test('defaults to boxing when no prefs stored', () async {
      final p = await makeProvider();
      expect(p.selectedWorkoutType, WorkoutType.boxing);
    });
  });

  // ── 2. Load from SharedPreferences ───────────────────────────────────────

  group('workout type — loaded from SharedPreferences on construction', () {
    test('restores cycling', () async {
      final p = await makeProvider(storedWorkoutType: 'cycling');
      expect(p.selectedWorkoutType, WorkoutType.cycling);
    });

    test('restores running', () async {
      final p = await makeProvider(storedWorkoutType: 'running');
      expect(p.selectedWorkoutType, WorkoutType.running);
    });

    test('restores other', () async {
      final p = await makeProvider(storedWorkoutType: 'other');
      expect(p.selectedWorkoutType, WorkoutType.other);
    });

    test('restores boxing explicitly', () async {
      final p = await makeProvider(storedWorkoutType: 'boxing');
      expect(p.selectedWorkoutType, WorkoutType.boxing);
    });

    test('unknown stored value falls back to boxing', () async {
      final p = await makeProvider(storedWorkoutType: 'ultramarathon');
      expect(p.selectedWorkoutType, WorkoutType.boxing);
    });
  });

  // ── 3. Persisted by setWorkoutType ────────────────────────────────────────

  group('workout type — setWorkoutType persists to SharedPreferences', () {
    test('persists cycling', () async {
      final p = await makeProvider();
      p.setWorkoutType(WorkoutType.cycling);
      await drain();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('workoutType'), 'cycling');
    });

    test('persists running', () async {
      final p = await makeProvider();
      p.setWorkoutType(WorkoutType.running);
      await drain();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('workoutType'), 'running');
    });

    test('persists other', () async {
      final p = await makeProvider();
      p.setWorkoutType(WorkoutType.other);
      await drain();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('workoutType'), 'other');
    });

    test('in-memory value is updated immediately (before save completes)', () async {
      final p = await makeProvider();
      p.setWorkoutType(WorkoutType.running);
      expect(p.selectedWorkoutType, WorkoutType.running);
    });

    test('survives provider reconstruction — cycling persists across restart', () async {
      SharedPreferences.setMockInitialValues({});
      final p1 = WorkoutProvider(tts: FakeTtsService(), workout: FakeWorkoutService());
      await drain();

      p1.setWorkoutType(WorkoutType.cycling);
      await drain(); // ensure savePrefs completes before p2 reads

      final p2 = WorkoutProvider(tts: FakeTtsService(), workout: FakeWorkoutService());
      await drain();

      expect(p2.selectedWorkoutType, WorkoutType.cycling,
          reason: 'Workout type must survive provider reconstruction');
    });

    test('survives provider reconstruction — running persists', () async {
      SharedPreferences.setMockInitialValues({});
      final p1 = WorkoutProvider(tts: FakeTtsService(), workout: FakeWorkoutService());
      await drain();

      p1.setWorkoutType(WorkoutType.running);
      await drain();

      final p2 = WorkoutProvider(tts: FakeTtsService(), workout: FakeWorkoutService());
      await drain();

      expect(p2.selectedWorkoutType, WorkoutType.running);
    });

    test('survives provider reconstruction — walking persists', () async {
      SharedPreferences.setMockInitialValues({});
      final p1 = WorkoutProvider(tts: FakeTtsService(), workout: FakeWorkoutService());
      await drain();

      p1.setWorkoutType(WorkoutType.walking);
      await drain();

      final p2 = WorkoutProvider(tts: FakeTtsService(), workout: FakeWorkoutService());
      await drain();

      expect(p2.selectedWorkoutType, WorkoutType.walking);
    });

    test('survives provider reconstruction — hiking persists', () async {
      SharedPreferences.setMockInitialValues({});
      final p1 = WorkoutProvider(tts: FakeTtsService(), workout: FakeWorkoutService());
      await drain();

      p1.setWorkoutType(WorkoutType.hiking);
      await drain();

      final p2 = WorkoutProvider(tts: FakeTtsService(), workout: FakeWorkoutService());
      await drain();

      expect(p2.selectedWorkoutType, WorkoutType.hiking);
    });
  });
}
