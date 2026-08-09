import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';
import 'helpers/fakes.dart';

// Start/stop lifecycle guards:
//  • a second start() while starting/running must not reach native again
//    (it used to leak the first run's stream subscriptions and ask for a
//    second HKWorkoutSession over the live one);
//  • stop() racing the native 'stopped' status event must persist the
//    session exactly once (both paths used to compute + save it).

class _CountingWorkoutService extends FakeWorkoutService {
  _CountingWorkoutService() : super(healthProfile: kTestHealthProfile);

  int startCalls = 0;
  int stopCalls = 0;
  Duration startDelay = Duration.zero;

  @override
  Future<bool> startWorkout(
      {String workoutType = 'other', int announceIntervalSeconds = 15}) async {
    startCalls++;
    if (startDelay > Duration.zero) await Future.delayed(startDelay);
    return true;
  }

  @override
  Future<void> stopWorkout() async {
    stopCalls++;
  }

}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = FakeWakelock();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('shb_start_guard_');
    PathProviderPlatform.instance = FakePathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  List<File> sessionFiles() {
    final dir = Directory('${tempDir.path}/sessions');
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.json') && !f.path.endsWith('in_progress.json'))
        .toList();
  }

  test('a second start() while starting is a no-op', () async {
    final fake = _CountingWorkoutService()
      ..startDelay = const Duration(milliseconds: 50);
    final p = WorkoutProvider(workout: fake, tts: FakeTtsService());
    await p.initialized;

    final first = p.start();
    final second = p.start(); // lands while state == starting
    await Future.wait([first, second]);

    expect(fake.startCalls, 1,
        reason: 'the second start must not reach native');
    expect(p.state, MonitoringState.running);

    // And again while running.
    await p.start();
    expect(fake.startCalls, 1);
    p.dispose();
  });

  test('stop() racing the native stopped event persists exactly once',
      () async {
    final fake = _CountingWorkoutService();
    final p = WorkoutProvider(workout: fake, tts: FakeTtsService());
    await p.initialized;
    await p.start();
    expect(p.state, MonitoringState.running);

    // Two samples so there is a session worth persisting.
    fake.pushHr(100);
    await Future.delayed(Duration.zero);
    fake.pushHr(110);
    await Future.delayed(Duration.zero);
    expect(p.bpmHistory.length, 2);

    // User taps stop while native also reports 'stopped' (background kill,
    // HealthKit timeout…). Whichever wins must claim the transition; the
    // other must no-op.
    final stopping = p.stop();
    fake.pushStatus({'type': 'state', 'value': 'stopped'});
    await stopping;
    await Future.delayed(const Duration(milliseconds: 20));

    expect(p.state, MonitoringState.stopped);
    expect(sessionFiles().length, 1,
        reason: 'the session must be persisted exactly once');
    expect(fake.stopCalls, 1);

    // A late second stop() is also a no-op.
    await p.stop();
    expect(fake.stopCalls, 1);
    expect(sessionFiles().length, 1);
    p.dispose();
  });

  test('a late HR event after stop() does not mutate the finished session',
      () async {
    final fake = _CountingWorkoutService();
    final p = WorkoutProvider(workout: fake, tts: FakeTtsService());
    await p.initialized;
    await p.start();
    fake.pushHr(100);
    await Future.delayed(Duration.zero);
    fake.pushHr(110);
    await Future.delayed(Duration.zero);

    await p.stop();
    final lenAfterStop = p.bpmHistory.length;

    // Direct injection (the stream is already cancelled): the state guard in
    // _onHeartRate must drop it.
    p.simulateHeartRateForTest(180);
    expect(p.bpmHistory.length, lenAfterStop);
    expect(p.currentBpm, isNot(180));
    p.dispose();
  });
}
