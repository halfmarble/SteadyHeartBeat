import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';
import 'package:steady_heart_beat/services/workout_service.dart';
import 'package:steady_heart_beat/services/tts_service.dart';

// Start/stop lifecycle guards:
//  • a second start() while starting/running must not reach native again
//    (it used to leak the first run's stream subscriptions and ask for a
//    second HKWorkoutSession over the live one);
//  • stop() racing the native 'stopped' status event must persist the
//    session exactly once (both paths used to compute + save it).

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

class _CountingWorkoutService extends WorkoutService {
  final _hrCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _statusCtrl = StreamController<Map<String, dynamic>>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  Duration startDelay = Duration.zero;

  void pushHr(double bpm) => _hrCtrl.add({'bpm': bpm});
  void pushStatus(Map<String, dynamic> event) => _statusCtrl.add(event);

  @override
  Future<bool> requestAuthorization() async => true;
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

  @override
  Future<void> setAnnounceInterval(int seconds) async {}
  @override
  Future<void> setSaveToHealth(bool enabled) async {}
  @override
  Future<void> setUseImperial(bool imperial) async {}
  @override
  Future<Map<String, dynamic>> checkAirPods() async =>
      {'connected': true, 'activeOnThisDevice': true, 'name': 'Test AirPods'};
  @override
  Future<bool> bindAirPods() async => true;
  @override
  Future<Map<String, dynamic>?> getHealthProfile() async => {
        'available': true,
        'age': 40,
        'maxHeartRate': 180,
        'zone1End': 90,
        'zone2Start': 108,
        'zone3Start': 126,
        'zone4Start': 144,
        'zone5Start': 162,
      };
  @override
  Future<Map<String, dynamic>?> getRecentHRV() async => null;
  @override
  Future<Map<String, dynamic>?> getRestingHR() async => null;
  @override
  Future<Map<String, dynamic>?> getVO2Max() async => null;
  @override
  Future<Map<String, dynamic>?> getBodyMass() async => null;
  @override
  Future<List<Map<String, dynamic>>> listVoices() async => const [];
  @override
  Future<String> currentVoiceIdentifier() async => '';
  @override
  Future<void> previewVoice(String identifier, {String? text}) async {}
  @override
  Future<void> setZones(List<int> bounds) async {}
  @override
  Future<void> setZoneCoaching(
      {required bool enabled, required int targetZone}) async {}
  @override
  Future<void> setBoxingRounds(
      {required bool enabled,
      required int roundSecs,
      required int restSecs,
      required int totalRounds,
      required int warnSecs,
      required int prepSecs}) async {}
  @override
  Stream<Map<String, dynamic>> get heartRateStream => _hrCtrl.stream;
  @override
  Stream<Map<String, dynamic>> get statusStream => _statusCtrl.stream;
}

class _FakeTtsService extends TtsService {
  @override
  Future<void> init() async {}
  @override
  Future<void> setVoice(String gender) async {}
  @override
  Future<void> speak(String text, {bool force = false}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _FakeWakelock();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('shb_start_guard_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
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
    final p = WorkoutProvider(workout: fake, tts: _FakeTtsService());
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
    final p = WorkoutProvider(workout: fake, tts: _FakeTtsService());
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
    final p = WorkoutProvider(workout: fake, tts: _FakeTtsService());
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
