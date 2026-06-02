import 'package:flutter/services.dart';

class WorkoutService {
  static const _method = MethodChannel('steadyheartbeat/workout');
  static const _hrEvents = EventChannel('steadyheartbeat/heartrate');
  static const _statusEvents = EventChannel('steadyheartbeat/status');

  Future<bool> requestAuthorization() async {
    final result = await _method.invokeMethod<bool>('requestAuthorization');
    return result ?? false;
  }

  Future<bool> startWorkout({
    String workoutType = 'other',
    int announceIntervalSeconds = 15,
  }) async {
    // Pass the announce interval into startWorkout so the native periodic timer
    // starts at the user's chosen cadence immediately. Setting it separately
    // afterward left the first announces running at the native default until
    // the follow-up call landed (visible with short intervals like 2 s).
    final result = await _method.invokeMethod<bool>(
        'startWorkout', {'type': workoutType, 'seconds': announceIntervalSeconds});
    return result ?? false;
  }

  Future<void> stopWorkout() async {
    await _method.invokeMethod('stopWorkout');
  }

  /// Sets the periodic announce interval on the native side. Required because
  /// Flutter's Dart isolate is suspended when the app is backgrounded, so a
  /// Dart Timer.periodic stops firing — native owns the periodic announce.
  Future<void> setAnnounceInterval(int seconds) async {
    await _method.invokeMethod('setAnnounceInterval', {'seconds': seconds});
  }

  /// Whether finished workouts are saved to Apple Health (true) or discarded so
  /// they never leave the device (false). Read natively at workout stop, so it
  /// must be pushed before the workout ends (we push it at start and on toggle).
  Future<void> setSaveToHealth(bool enabled) async {
    await _method.invokeMethod('setSaveToHealth', {'enabled': enabled});
  }

  /// Pushes the 5 zone-start BPM boundaries (50/60/70/80/90% max HR, ascending)
  /// to native so the background announce can name the zone.
  Future<void> setZones(List<int> bounds) async {
    await _method.invokeMethod('setZones', {'bounds': bounds});
  }

  /// Enables/disables zone coaching and sets the target zone (0 = none, 1–5).
  Future<void> setZoneCoaching({required bool enabled, required int targetZone}) async {
    await _method.invokeMethod(
        'setZoneCoaching', {'enabled': enabled, 'targetZone': targetZone});
  }

  /// Pushes boxing round-timer config to native. The native side starts the
  /// round timer at workout start (boxing only) and drives the spoken cues +
  /// 'round' status events. [totalRounds] 0 = unlimited; [warnSecs]/[prepSecs]
  /// 0 = off.
  Future<void> setBoxingRounds({
    required bool enabled,
    required int roundSecs,
    required int restSecs,
    required int totalRounds,
    required int warnSecs,
    required int prepSecs,
  }) async {
    await _method.invokeMethod('setBoxingRounds', {
      'enabled': enabled,
      'roundSecs': roundSecs,
      'restSecs': restSecs,
      'totalRounds': totalRounds,
      'warnSecs': warnSecs,
      'prepSecs': prepSecs,
    });
  }

  /// Triggers the system notification permission prompt. Returns true if the
  /// user granted permission, false otherwise.
  Future<bool> requestNotificationPermission() async {
    final result = await _method.invokeMethod<bool>('requestNotificationPermission');
    return result ?? false;
  }

  /// Returns one of: notDetermined / denied / authorized / provisional /
  /// ephemeral / unknown. Use to decide what to show in Preferences.
  Future<String> getNotificationStatus() async {
    final result = await _method.invokeMethod<String>('getNotificationStatus');
    return result ?? 'unknown';
  }

  /// Lists English voices installed on this iPhone, best quality first. Each
  /// entry: {identifier, name, quality ('premium'|'enhanced'|'default'),
  /// gender, language} (all String).
  Future<List<Map<String, dynamic>>> listVoices() async {
    final result = await _method.invokeListMethod('listVoices');
    if (result == null) return const [];
    return result
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// The identifier of the voice the announce path is currently using —
  /// including the resolved "best available" voice when none is chosen.
  Future<String> currentVoiceIdentifier() async {
    final result = await _method.invokeMethod<String>('currentVoiceIdentifier');
    return result ?? '';
  }

  /// Plays a spoken sample of [identifier] (empty = automatic/best) for the
  /// picker. Foreground only — uses a plain synthesizer, not the workout engine.
  Future<void> previewVoice(String identifier, {String? text}) async {
    await _method.invokeMethod('previewVoice', {
      'identifier': identifier,
      'text': ?text,
    });
  }

  /// Returns most recent resting HR: {'bpm': double, 'timestamp': double}.
  Future<Map<String, dynamic>?> getRestingHR() async {
    final result = await _method.invokeMapMethod<String, dynamic>('getRestingHR');
    return result;
  }

  /// Returns most recent VO2 max: {'mlPerKgMin': double, 'timestamp': double}.
  Future<Map<String, dynamic>?> getVO2Max() async {
    final result = await _method.invokeMapMethod<String, dynamic>('getVO2Max');
    return result;
  }

  /// Returns most recent body mass: {'kg': double, 'timestamp': double (epoch seconds)}.
  Future<Map<String, dynamic>?> getBodyMass() async {
    final result = await _method.invokeMapMethod<String, dynamic>('getBodyMass');
    return result;
  }

  /// Returns most recent resting HRV: {'ms': double, 'timestamp': double (epoch seconds)}.
  /// Null if no Apple Watch HRV data exists.
  Future<Map<String, dynamic>?> getRecentHRV() async {
    final result = await _method.invokeMapMethod<String, dynamic>('getRecentHRV');
    return result;
  }

  /// Returns age-derived HR zones from HealthKit DOB.
  /// Keys: available (bool); age, maxHeartRate, zone1End, zone2Start,
  /// zone3Start, zone4Start, zone5Start (all int) when available is true.
  Future<Map<String, dynamic>?> getHealthProfile() async {
    final result = await _method.invokeMapMethod<String, dynamic>('getHealthProfile');
    return result;
  }

  /// Returns the `airpods.pro` SF Symbol rendered to PNG bytes at the given pointSize,
  /// white on transparent background. Returns null if the symbol is unavailable.
  Future<Uint8List?> getAirPodsIcon({double pointSize = 120}) async {
    final result = await _method.invokeMethod<Uint8List>(
        'getAirPodsIcon', {'pointSize': pointSize});
    return result;
  }

  /// Returns {'connected': bool, 'activeOnThisDevice': bool, 'name': String}.
  Future<Map<String, dynamic>> checkAirPods() async {
    final result = await _method.invokeMapMethod<String, dynamic>('checkAirPods');
    return result ?? {'connected': false, 'name': ''};
  }

  /// Attempts to pull the AirPods audio route — and the heart-rate binding that
  /// follows it — onto this iPhone by producing a short spoken cue, instead of
  /// asking the user to play Music manually. Returns true if the AirPods ended
  /// up active on this device.
  Future<bool> bindAirPods() async {
    final result = await _method.invokeMethod('bindAirPods');
    return result as bool? ?? false;
  }

  /// Stream of live workout metrics. Each event carries whichever fields HealthKit
  /// just collected — any of: 'bpm', 'kcal', 'respiratoryRate', 'steps',
  /// 'distanceMeters', 'floorsClimbed' (all double).
  Stream<Map<String, dynamic>> get heartRateStream =>
      _hrEvents.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map));

  /// Stream of status events: {'type': 'state'|'error', 'value': String}
  Stream<Map<String, dynamic>> get statusStream =>
      _statusEvents.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map));
}
