// Shared test fakes. One definition of the platform doubles instead of a
// private copy per test file (they had already drifted apart). test/plus/
// keeps its own mirrors deliberately, so the public export's test tree never
// references the module.

import 'dart:async';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:steady_heart_beat/services/tts_service.dart';
import 'package:steady_heart_beat/services/workout_service.dart';

/// The standard age-40 test profile: maxHR 180 with round-number zones.
const Map<String, dynamic> kTestHealthProfile = {
  'available': true,
  'age': 40,
  'maxHeartRate': 180,
  'zone1End': 90,
  'zone2Start': 108,
  'zone3Start': 126,
  'zone4Start': 144,
  'zone5Start': 162,
};

/// No-op wakelock so start/error paths that toggle the screen lock don't hit
/// the unmocked platform channel under test.
class FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

/// path_provider with no real plugin: points the docs AND temp dirs at a test
/// directory so the file-backed stores and the export flow can be exercised.
class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  FakePathProvider(this.basePath);
  final String basePath;
  @override
  Future<String?> getApplicationDocumentsPath() async => basePath;
  @override
  Future<String?> getTemporaryPath() async => basePath;
}

/// Records every speak() call; synchronous; no platform I/O.
class FakeTtsService extends TtsService {
  final List<String> spoken = [];
  @override
  Future<void> init() async {}
  @override
  Future<void> speak(String text, {bool force = false}) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

/// Inert workout service: every native call succeeds and does nothing, with
/// pushable HR/status streams. The health profile and AirPods answers are
/// constructor-injectable so per-file specializations stay one-liners.
class FakeWorkoutService extends WorkoutService {
  FakeWorkoutService({
    this.healthProfile = const {'available': false},
    this.airPods = const {
      'connected': true,
      'activeOnThisDevice': true,
      'name': 'Test AirPods',
    },
  });

  final Map<String, dynamic> healthProfile;
  final Map<String, dynamic> airPods;

  final _hrCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _statusCtrl = StreamController<Map<String, dynamic>>.broadcast();

  void pushHr(double bpm) => _hrCtrl.add({'bpm': bpm});
  void pushStatus(Map<String, dynamic> event) => _statusCtrl.add(event);
  Future<void> closeStreams() async {
    await _hrCtrl.close();
    await _statusCtrl.close();
  }

  /// The last unit preference pushed to native (null = never pushed).
  bool? lastUseImperial;

  @override
  Future<bool> requestAuthorization() async => true;
  @override
  Future<bool> startWorkout(
          {String workoutType = 'other', int announceIntervalSeconds = 15}) async =>
      true;
  @override
  Future<void> stopWorkout() async {}
  @override
  Future<void> setAnnounceInterval(int seconds) async {}
  @override
  Future<void> setSaveToHealth(bool enabled) async {}
  @override
  Future<void> setUseImperial(bool imperial) async {
    lastUseImperial = imperial;
  }

  @override
  Future<Map<String, dynamic>> checkAirPods() async => airPods;
  @override
  Future<bool> bindAirPods() async => true;
  @override
  Future<Map<String, dynamic>?> getHealthProfile() async => healthProfile;
  @override
  Future<Map<String, dynamic>?> getRecentHRV() async => null;
  @override
  Future<Map<String, dynamic>?> getRestingHR() async => null;
  @override
  Future<Map<String, dynamic>?> getVO2Max() async => null;
  @override
  Future<Map<String, dynamic>?> getBodyMass() async => null;
  @override
  Future<void> speakGreeting(String text) async {}
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
