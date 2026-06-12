import 'dart:async';
import 'dart:math' show max, min;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/workout_service.dart';
import '../services/tts_service.dart';
import '../services/session_storage_service.dart';
import '../services/health_profile_store.dart';
import '../services/health_import_service.dart';
import '../constants.dart';
import '../plus_api.dart';
import '../plus_binding.dart';

enum MonitoringState { idle, starting, running, error, stopped }

enum WorkoutType { walking, hiking, running, cycling, other, boxing }

extension WorkoutTypeX on WorkoutType {
  String get label => switch (this) {
    WorkoutType.boxing   => 'Boxing',
    WorkoutType.cycling  => 'Cycling',
    WorkoutType.running  => 'Running',
    WorkoutType.walking  => 'Walking',
    WorkoutType.hiking   => 'Hiking',
    WorkoutType.other    => 'Other',
  };
  String get hkKey => switch (this) {
    WorkoutType.boxing   => 'boxing',
    WorkoutType.cycling  => 'cycling',
    WorkoutType.running  => 'running',
    WorkoutType.walking  => 'walking',
    WorkoutType.hiking   => 'hiking',
    WorkoutType.other    => 'other',
  };
}

class BpmSample {
  final double secondsFromStart;
  final double bpm;
  const BpmSample(this.secondsFromStart, this.bpm);
}

class WorkoutProvider extends ChangeNotifier with WidgetsBindingObserver {
  final WorkoutService _workout;
  final TtsService _tts;

  MonitoringState state = MonitoringState.idle;
  double? currentBpm;
  double? currentKcal;
  double? currentRespiratoryRate;
  double? currentSteps;
  double? currentDistanceMeters;
  double? currentFloorsClimbed;
  // Barometric ascent (m) this session, tracked natively via CMAltimeter.
  double currentAscentMeters = 0;
  String? errorMessage;

  /// Gravitational work of the climb, W = m·g·h (kJ) — a deterministic Glass-Box
  /// energy term, distinct from HealthKit's calorie estimate. Uses the effective
  /// body mass (manual weight override → Apple Health → default).
  double get currentElevationWorkKJ =>
      effectiveBodyMassKg * 9.81 * currentAscentMeters / 1000;

  /// Metabolic-equivalent cost of the climb: gravitational work divided by the
  /// well-established ~23% efficiency of human locomotion against gravity.
  double get elevationKcal => currentElevationWorkKJ * 1000 / 0.23 / 4184;

  /// Set when the final session save fails. UI shows a banner; the in-progress
  /// recovery file is left behind so the next launch can pick the data up.
  String? saveError;

  /// Set when a workout starts without zone data (HealthKit didn't return a
  /// DOB). Zones, effort %, danger threshold all silently no-op without it —
  /// surfaced via SnackBar so the user knows to fix it.
  String? zonesWarning;

  /// Optional user-entered age. Used as a fallback when HealthKit DOB is
  /// unavailable. Setting this populates the same zone fields that HealthKit
  /// would, using the standard maxHR = 208 - 0.7 × age formula.
  int? manualAge;

  /// Sets manual age, derives zones, persists, and clears any zonesWarning.
  /// Passing null clears the manual age (and the derived zones, unless
  /// HealthKit later provides them).
  Future<void> setManualAge(int? age) async {
    if (age != null && age >= 1 && age <= 120) {
      manualAge = age;
      healthAge = age;
      maxHeartRate = (208.0 - 0.7 * age).round();
      zone1End   = (maxHeartRate! * 0.50).round();
      zone2Start = (maxHeartRate! * 0.60).round();
      zone3Start = (maxHeartRate! * 0.70).round();
      zone4Start = (maxHeartRate! * 0.80).round();
      zone5Start = (maxHeartRate! * 0.90).round();
      dangerZoneThreshold = zone5Start!;
      zonesWarning = null;
      _safeNotify();
      await _saveHealthProfile();
    } else {
      // "Auto" — drop the manual override and fall back to Apple Health DOB.
      // Clear the manual-derived values, then re-read HealthKit, which restores
      // the age + zones if a DOB is available (and no-ops if not).
      manualAge = null;
      healthAge = null;
      maxHeartRate = null;
      zone1End = zone2Start = zone3Start = zone4Start = zone5Start = null;
      dangerZoneThreshold = kDefaultDangerBpm;
      _safeNotify();
      await _saveHealthProfile(); // persists cleared age + drops stale zones
      await _tryFetchHealthProfile(); // restore HK age + zones if available
    }
  }

  /// Biological sex used to grade VO₂max against sex-specific norms. [healthSex]
  /// is read from HealthKit; [manualSex] is a user override (wins when set).
  /// 'female' | 'male' | 'other' | null. Defaults to male norms when unknown
  /// (see health_norms.dart).
  String? healthSex;
  String? manualSex;
  String? get effectiveSex => manualSex ?? healthSex;

  /// Sets the manual sex override. 'female'/'male' set it; anything else (null,
  /// 'auto') clears the override and falls back to HealthKit.
  Future<void> setManualSex(String? sex) async {
    if (sex == 'female' || sex == 'male') {
      manualSex = sex;
      await _saveHealthProfile();
      _safeNotify();
    } else {
      manualSex = null;
      await _saveHealthProfile();
      _safeNotify();
      await _tryFetchHealthProfile(); // restore HK sex if available
    }
  }

  // Workout type chosen before starting
  WorkoutType selectedWorkoutType = WorkoutType.boxing;

  // Session timestamps
  DateTime? sessionStart;
  DateTime? sessionEnd;

  // Post-session summary (computed in stop())
  double? summaryMaxBpm;
  double? summaryMinBpm;
  double? summaryAvgBpm;
  double? summaryEffortPct;   // avgBpm / maxHR × 100
  Duration? summaryDuration;
  Map<int, double>? summaryHistogram; // bpm → seconds
  // Zone seconds computed once at session end: [brady, z1, z2, z3, z4, z5+]
  // null if zones not configured or session too short.
  List<double>? summaryZoneSecs;
  List<String> errorSteps = [];
  String airPodsName = '';
  bool airPodsConnected = false;

  // Live AirPods state for the home screen. Polled every 3 s while not in
  // a running workout so the idle UI reflects current connection without
  // requiring a Start tap. Distinct from airPodsConnected, which is the
  // snapshot taken at start() time.
  bool idleAirPodsConnected = false;
  bool idleAirPodsActiveHere = false;
  String idleAirPodsName = '';
  Timer? _idlePollTimer;
  static const _idlePollInterval = Duration(seconds: 3);

  // Age-derived HR zones (null when Health DOB is not available)
  int? healthAge;
  int? maxHeartRate;
  int? zone1End;   // Zone 1 start — 50% max HR (green)
  int? zone2Start; // Zone 2 start — 60% max HR (chartreuse)
  int? zone3Start; // Zone 3 start — 70% max HR (yellow)
  int? zone4Start; // Zone 4 start — 80% max HR (orange)
  int? zone5Start; // Zone 5 start — 90% max HR (red / danger)

  // Most recent resting metrics from Apple Watch (null = no Watch data)
  double? recentHrvMs;
  DateTime? recentHrvDate;
  // How recentHrvMs was derived: 'bed' = mean SDNN across last night's whole
  // in-bed span (sleep onset → out of bed, awake periods included — the
  // preferred, comparable resting reading); 'recent' = the single most recent
  // SDNN sample (fallback when no overnight reading exists). Drives the metric
  // label ("bed HRV" vs "resting HRV"). Null until first read.
  String? hrvSource;
  double? recentRestingHrBpm;
  // How recentRestingHrBpm was derived, mirroring [hrvSource]: 'bed' = mean
  // heart rate across last night's whole in-bed span ("bed HR"); 'recent' = the
  // single most recent restingHeartRate sample (fallback). Drives the label
  // ("bed HR" vs "resting HR"). Null until first read.
  String? restingHrSource;
  DateTime? recentRestingHrDate;
  double? recentVo2MaxMlPerKgMin;
  DateTime? recentVo2MaxDate;

  // Manual overrides for the resting metrics — used when Apple Watch data is
  // stale or absent (e.g. the Watch hasn't been worn in months). When set, the
  // manual value takes precedence everywhere; null falls back to HealthKit.
  double? manualHrvMs;
  double? manualVo2Max;
  double? manualRestingHr;

  double? get effectiveHrvMs        => manualHrvMs ?? recentHrvMs;
  double? get effectiveVo2Max       => manualVo2Max ?? recentVo2MaxMlPerKgMin;
  double? get effectiveRestingHrBpm => manualRestingHr ?? recentRestingHrBpm;

  // Body mass for the elevation energy term (W = m·g·h). Manual weight override
  // (Preferences) wins; else the latest Apple Health weight; else a default.
  double? autoBodyMassKg;
  DateTime? autoBodyMassDate;
  double? manualWeightKg;
  double get effectiveBodyMassKg => manualWeightKg ?? autoBodyMassKg ?? 75;

  // True when the auto (HealthKit) value is older than this and not overridden.
  static const int kStaleMetricDays = 30;
  bool _isStale(DateTime? d) =>
      d != null && DateTime.now().difference(d).inDays > kStaleMetricDays;
  bool get hrvStale        => manualHrvMs == null && _isStale(recentHrvDate);
  bool get vo2Stale        => manualVo2Max == null && _isStale(recentVo2MaxDate);
  bool get restingHrStale  => manualRestingHr == null && _isStale(recentRestingHrDate);

  Future<void> _setManualMetric(
      double? value, void Function(double?) assign) async {
    assign(value);
    _safeNotify();
    await _saveHealthProfile();
  }

  Future<void> setManualHrv(double? v) =>
      _setManualMetric(v, (x) => manualHrvMs = x);
  Future<void> setManualVo2Max(double? v) =>
      _setManualMetric(v, (x) => manualVo2Max = x);
  Future<void> setManualRestingHr(double? v) =>
      _setManualMetric(v, (x) => manualRestingHr = x);
  Future<void> setManualWeight(double? v) =>
      _setManualMetric(v, (x) => manualWeightKg = x);

  // Health authorization state shown in Preferences
  bool healthFetchPending = false;
  String? healthFetchError; // non-null when last fetch failed

  // Independent progress/error state for the manual "Refresh from Apple Health"
  // button, so it doesn't drive the authorize-access UI's spinner.
  bool healthRefreshPending = false;
  String? healthRefreshError;

  /// Count of stored (completed) sessions. Drives enabling/disabling the
  /// Export / Delete-All actions in Preferences. Refreshed at launch, after a
  /// delete-all, and whenever the data section appears.
  int sessionCount = 0;

  // Preferences
  // Selected announce voice. null identifier = "automatic": native picks the
  // best installed voice (Option A — premium > enhanced > default). voiceName is
  // kept only so Preferences can show the chosen voice without re-querying.
  String? voiceIdentifier;
  String? voiceName;
  int announceIntervalSeconds = 60;    // 0 (continuous) | 15 | 30 | 60
  bool deltaAnnounceEnabled = false;   // off by default — opt-in, see preferences
  int deltaThreshold = 10;             // BPM change that triggers immediate announce
  bool welcomeEnabled = true;          // spoken welcome at app launch
  // Zone coaching: when on, BPM announces name the zone ("142, zone 4"); with a
  // target zone (1–5, 0 = none) they also nudge "push"/"ease off". Needs zones
  // (age/DOB) configured — no-ops otherwise.
  bool zoneCoachingEnabled = false;
  int targetZone = 0;
  // Boxing round timer. Config persisted here, pushed to native at workout start
  // (native owns the clock so it survives backgrounding). totalRounds 0 = ∞.
  bool boxingRoundsEnabled = false;
  int roundSecs = 180;                 // 3:00 rounds (pro default)
  int restSecs = 60;                   // 1:00 rest
  int totalRounds = 12;                // 0 = unlimited
  bool roundWarnEnabled = true;        // "ten seconds" cue before round end
  // Live round state, updated from native 'round' status events.
  String roundPhase = 'done';          // prep | warmup | work | rest | cooldown | done
  int currentRound = 0;
  int roundTotal = 0;
  int roundRemaining = 0;
  int dangerZoneThreshold = 175;       // BPM above which the chart shows a danger band
  Set<String> healthConditions = {};   // e.g. {'cardiovascular', 'parkinsons'}
  bool useImperial = true;             // true = ft/mi, false = m/km
  // Save finished workouts to Apple Health (Fitness rings + iCloud Health sync).
  // Off = the workout is discarded natively and stays on this device only.
  bool saveToHealth = true;

  final List<BpmSample> bpmHistory = [];
  // Incrementally-maintained smoothed BPM values — avoids O(n) full
  // recomputation on every chart rebuild. Updated on each new HR sample.
  final List<double> _smoothedBpms = [];
  static const _smoothWindow = kSmoothWindow;

  DateTime? _sessionStart;

  StreamSubscription? _hrSub;
  StreamSubscription? _statusSub;
  Timer? _noDataTimer;
  Timer? _hrSilenceTimer;
  Timer? _dimTimer;
  double? _deltaBpmBaseline; // resets only on delta fire — native owns the periodic timer
  // Whether the opening reading of this workout has been announced yet. The first
  // valid sample is always spoken immediately (independent of the delta toggle and
  // the announce interval) so the user gets an opening BPM right after the
  // "Monitoring heart rate" start confirmation.
  bool _firstSampleAnnounced = false;
  double? _latestBpm;

  // Spoken once per app launch (see _maybeSpeakWelcome). The provider lives for
  // the whole process, so this naturally fires on a cold launch and not on every
  // background→foreground resume.
  bool _welcomedThisLaunch = false;

  /// Completes when the initial [_loadPrefs] pass (including the health-data
  /// migration) has finished. Mainly for tests, which need a deterministic
  /// point to assert post-load state rather than racing the async constructor.
  late final Future<void> initialized;

  /// The SHB+ paid module — inert [NoPlusFeatures] in the public free core,
  /// the real implementation (lib/plus/) in the private repo, per the binding
  /// in plus_binding.dart. Tests inject a [plusFactory] to capture pushes.
  late final PlusFeatures plus;

  WorkoutProvider(
      {WorkoutService? workout,
      TtsService? tts,
      PlusFeatures Function(WorkoutProvider provider)? plusFactory})
      : _workout = workout ?? WorkoutService(),
        _tts = tts ?? TtsService() {
    plus = (plusFactory ?? createPlusFeatures)(this);
    initialized = _loadPrefs();
    WidgetsBinding.instance.addObserver(this);
    _startIdlePoll();
  }

  /// Called by the SHB+ module when its state changes: rebroadcasts to this
  /// provider's listeners and optionally persists preferences (the module's
  /// settings ride [savePrefs]).
  void plusChanged({bool persist = false}) {
    if (persist) savePrefs();
    _safeNotify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The idle AirPods poll is a Dart Timer.periodic, which suspends while the
    // app is backgrounded. Re-check immediately on resume so buds inserted while
    // we were away show up at once rather than after the next 3 s tick.
    if (state == AppLifecycleState.resumed && _idlePollTimer != null) {
      _pollAirPods();
    }
  }

  void _startIdlePoll() {
    _idlePollTimer?.cancel();
    _pollAirPods();
    _idlePollTimer = Timer.periodic(_idlePollInterval, (_) => _pollAirPods());
  }

  void _stopIdlePoll() {
    _idlePollTimer?.cancel();
    _idlePollTimer = null;
  }

  Future<void> _pollAirPods() async {
    if (_disposed) return;
    final info = await _workout.checkAirPods();
    if (_disposed) return;
    final connected = info['connected'] as bool? ?? false;
    final active = info['activeOnThisDevice'] as bool? ?? true;
    final name = info['name'] as String? ?? '';
    if (connected != idleAirPodsConnected ||
        active != idleAirPodsActiveHere ||
        name != idleAirPodsName) {
      idleAirPodsConnected = connected;
      idleAirPodsActiveHere = active;
      idleAirPodsName = name;
      _safeNotify();
    }
  }

  // ── Test hooks ───────────────────────────────────────────────────────────────

  /// Directly exercises _onHeartRate without going through the stream.
  @visibleForTesting
  void simulateHeartRateForTest(double bpm) => _onHeartRate({'bpm': bpm});

  /// Puts the provider into running state without a real workout session.
  @visibleForTesting
  void setRunningForTest() {
    state = MonitoringState.running;
    _sessionStart ??= DateTime.now();
  }

  /// Directly invokes the interval-timer callback body so timer tests don't
  /// need real elapsed time.
  @visibleForTesting
  void triggerIntervalAnnounceForTest() {
    final bpm = _latestBpm;
    if (bpm != null && state == MonitoringState.running) {
      _deltaBpmBaseline = bpm;
      _announce(bpm);
    }
  }

  @visibleForTesting
  double? get deltaBpmBaselineForTest => _deltaBpmBaseline;

  @visibleForTesting
  double? get latestBpmForTest => _latestBpm;

  /// Injects a BpmSample with an explicit timestamp, bypassing DateTime.now().
  /// Allows tests to construct sessions with known durations for zone-time checks.
  @visibleForTesting
  void addBpmSampleForTest(double secondsFromStart, double bpm) {
    if (_sessionStart == null) {
      _sessionStart = DateTime.now();
      sessionStart = _sessionStart;
    }
    bpmHistory.add(BpmSample(secondsFromStart, bpm));
    _latestBpm = bpm;
    currentBpm = bpm;
    _updateSmoothedBpms();
    notifyListeners();
  }

  /// Triggers summary computation + transitions to stopped state without
  /// going through the full stop() path (avoids WakelockPlus platform channel).
  @visibleForTesting
  void computeSummaryForTest() {
    if (bpmHistory.length >= 2) {
      sessionEnd ??= DateTime.now();
      _computeSummary();
      state = MonitoringState.stopped;
      notifyListeners();
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    voiceIdentifier = prefs.getString('voiceIdentifier');
    voiceName = prefs.getString('voiceName');
    announceIntervalSeconds = prefs.getInt('announceInterval') ?? 60;
    deltaAnnounceEnabled = prefs.getBool('deltaAnnounceEnabled') ?? false;
    deltaThreshold = prefs.getInt('deltaThreshold') ?? 10;
    welcomeEnabled = prefs.getBool('welcomeEnabled') ?? true;
    zoneCoachingEnabled = prefs.getBool('zoneCoachingEnabled') ?? false;
    targetZone = prefs.getInt('targetZone') ?? 0;
    boxingRoundsEnabled = prefs.getBool('boxingRoundsEnabled') ?? false;
    roundSecs = prefs.getInt('roundSecs') ?? 180;
    restSecs = prefs.getInt('restSecs') ?? 60;
    totalRounds = prefs.getInt('totalRounds') ?? 12;
    roundWarnEnabled = prefs.getBool('roundWarnEnabled') ?? true;
    plus.loadPrefs(prefs);
    useImperial = prefs.getBool('useImperial') ?? true;
    saveToHealth = prefs.getBool('saveToHealth') ?? true;
    final wt = prefs.getString('workoutType') ?? 'boxing';
    selectedWorkoutType = WorkoutType.values.firstWhere(
      (t) => t.hkKey == wt, orElse: () => WorkoutType.boxing);

    // Personal health data lives in the backup-excluded HealthProfileStore, not
    // shared_preferences. Each field falls back to its legacy prefs key so
    // existing installs migrate seamlessly; _stripLegacyHealthPrefs() (below)
    // then clears those keys out of the backed-up NSUserDefaults plist.
    final health = await HealthProfileStore.load();
    int? hInt(String k) => (health[k] as num?)?.toInt() ?? prefs.getInt(k);
    double? hDouble(String k) => (health[k] as num?)?.toDouble() ?? prefs.getDouble(k);
    String? hString(String k) => health[k] as String? ?? prefs.getString(k);

    healthConditions = ((health['healthConditions'] as List?)?.cast<String>() ??
        prefs.getStringList('healthConditions') ?? const <String>[]).toSet();
    dangerZoneThreshold = hInt('dangerZoneThreshold') ?? 175;
    // Restore Health-derived zones from last session
    healthAge = hInt('healthAge');
    maxHeartRate = hInt('maxHeartRate');
    zone1End = hInt('zone1End');
    zone2Start = hInt('zone2Start');
    zone3Start = hInt('zone3Start');
    zone4Start = hInt('zone4Start');
    zone5Start = hInt('zone5Start');
    if (zone5Start != null) dangerZoneThreshold = zone5Start!;
    // Manual overrides for resting metrics (stale/absent Watch data).
    manualHrvMs = hDouble('manualHrv');
    manualVo2Max = hDouble('manualVo2Max');
    manualRestingHr = hDouble('manualRestingHr');
    manualWeightKg = hDouble('manualWeight');
    // Manual age (fallback when HealthKit DOB isn't available). If set and no
    // HealthKit zones loaded, derive zones from it now.
    manualAge = hInt('manualAge');
    manualSex = hString('manualSex');
    healthSex = hString('healthSex');
    if (manualAge != null && healthAge == null) {
      healthAge = manualAge;
      maxHeartRate = (208.0 - 0.7 * manualAge!).round();
      zone1End   = (maxHeartRate! * 0.50).round();
      zone2Start = (maxHeartRate! * 0.60).round();
      zone3Start = (maxHeartRate! * 0.70).round();
      zone4Start = (maxHeartRate! * 0.80).round();
      zone5Start = (maxHeartRate! * 0.90).round();
      dangerZoneThreshold = zone5Start!;
    }
    // One-time migration: rewrite health data into the backup-excluded store,
    // and purge the legacy copies from the backed-up shared_preferences plist
    // ONLY once the excluded write has landed — otherwise we'd drop the sole
    // surviving copy. If the store is unavailable, the legacy keys stay and the
    // next launch retries.
    if (await _saveHealthProfile()) {
      await _stripLegacyHealthPrefs(prefs);
    }
    // The store/strip awaits above push this notify past the synchronous window;
    // guard against the provider having been disposed in the meantime.
    if (_disposed) return;
    _safeNotify();
    await _tts.init();
    await _tts.setVoice(voiceIdentifier ?? '');
    // Recover any in-progress workout that didn't get a clean save (app killed,
    // OOM, force-quit) by computing a summary from the last persisted snapshot.
    await _recoverOrphanSession();
    // Seed the session count so the Export / Delete-All buttons start in the
    // correct enabled/disabled state.
    refreshSessionCount();
    // If we have no persisted health zones, try a silent HealthKit fetch now.
    // This works if the user previously granted HealthKit access; silently
    // no-ops if not yet authorized.
    if (healthAge == null) _tryFetchHealthProfile();
    // Always refresh Watch-derived metrics on startup — they change nightly
    _fetchRecentHRV();
    _fetchRestingHR();
    _fetchVO2Max();
    _fetchBodyMass();
    // Greet the user once the chosen voice is loaded — confirms the voice + the
    // AirPods route, and nudges them to connect the buds if they aren't.
    _maybeSpeakWelcome();
  }

  /// Speaks a short welcome at launch (once), in the selected voice, through the
  /// foreground preview path (the workout engine isn't running yet). The text
  /// adapts to whether AirPods are connected so it doubles as a "put in your
  /// AirPods" nudge. Routes to the AirPods when present, the speaker otherwise.
  Future<void> _maybeSpeakWelcome() async {
    if (_welcomedThisLaunch || _disposed || !welcomeEnabled) return;
    _welcomedThisLaunch = true;
    final info = await _workout.checkAirPods();
    if (_disposed) return;
    final ready = (info['connected'] as bool? ?? false) &&
        (info['activeOnThisDevice'] as bool? ?? true);
    final text = ready
        ? 'Welcome to SteadyHeartBeat. Your AirPods are connected. Tap start when you are ready.'
        : 'Welcome to SteadyHeartBeat. Put in your AirPods Pro to begin.';
    await _workout.previewVoice('', text: text);
  }

  Future<void> savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (voiceIdentifier != null) {
      await prefs.setString('voiceIdentifier', voiceIdentifier!);
    } else {
      await prefs.remove('voiceIdentifier');
    }
    if (voiceName != null) {
      await prefs.setString('voiceName', voiceName!);
    } else {
      await prefs.remove('voiceName');
    }
    await prefs.setInt('announceInterval', announceIntervalSeconds);
    await prefs.setBool('deltaAnnounceEnabled', deltaAnnounceEnabled);
    await prefs.setInt('deltaThreshold', deltaThreshold);
    await prefs.setBool('welcomeEnabled', welcomeEnabled);
    await prefs.setBool('zoneCoachingEnabled', zoneCoachingEnabled);
    await prefs.setInt('targetZone', targetZone);
    await prefs.setBool('boxingRoundsEnabled', boxingRoundsEnabled);
    await prefs.setInt('roundSecs', roundSecs);
    await prefs.setInt('restSecs', restSecs);
    await prefs.setInt('totalRounds', totalRounds);
    await prefs.setBool('roundWarnEnabled', roundWarnEnabled);
    await plus.savePrefs(prefs);
    await prefs.setString('workoutType', selectedWorkoutType.hkKey);
    await prefs.setBool('useImperial', useImperial);
    await prefs.setBool('saveToHealth', saveToHealth);
    await _tts.setVoice(voiceIdentifier ?? '');
  }

  /// Called from Preferences when the user taps "Authorize Health Access".
  /// Re-triggers HealthKit authorization and attempts to read DOB.
  Future<void> requestHealthZones() async {
    healthFetchPending = true;
    healthFetchError = null;
    notifyListeners();

    final authorized = await _workout.requestAuthorization();
    if (!authorized) {
      healthFetchPending = false;
      healthFetchError = 'Health access denied. Enable in Settings → Privacy → Health → SteadyHeartBeat.';
      notifyListeners();
      return;
    }

    await _tryFetchHealthProfile();

    healthFetchPending = false;
    if (healthAge == null) {
      healthFetchError = 'Date of birth not found. Open the Health app → your profile → Health Details and add your date of birth.';
    }
    notifyListeners();
  }

  Future<void> _tryFetchHealthProfile() async {
    final profile = await _workout.getHealthProfile();
    if (profile == null) return;
    // Sex is independent of DOB — read it whether or not zones are available.
    final s = profile['sex'] as String?;
    if (s != null && (s == 'female' || s == 'male' || s == 'other')) {
      healthSex = s;
      _safeNotify();
      await _saveHealthProfile();
    }
    if (profile['available'] == true) {
      healthAge = profile['age'] as int?;
      maxHeartRate = profile['maxHeartRate'] as int?;
      zone1End = profile['zone1End'] as int?;
      zone2Start = profile['zone2Start'] as int?;
      zone3Start = profile['zone3Start'] as int?;
      zone4Start = profile['zone4Start'] as int?;
      zone5Start = profile['zone5Start'] as int?;
      if (zone5Start != null) dangerZoneThreshold = zone5Start!;
      // HealthKit is the authoritative source when available — clear any prior
      // manual override so the age picker locks to the HK value (the UI uses
      // manualAge != null as the signal that the picker should be editable).
      if (manualAge != null) manualAge = null;
      _safeNotify();
      await _saveHealthProfile();
    }
  }

  /// Incrementally recomputes only the tail of the smoothed BPM cache.
  /// O(window_size) per call instead of O(n) for a full recompute.
  void _updateSmoothedBpms() {
    final n = bpmHistory.length;
    // Only the last (window + window÷2) positions can change when one sample
    // is appended, because the sliding window reaches back that far.
    final startIdx = max(0, n - _smoothWindow - _smoothWindow ~/ 2);
    for (int i = startIdx; i < n; i++) {
      final lo = max(0, i - _smoothWindow ~/ 2);
      final hi = min(n, lo + _smoothWindow);
      final avg = bpmHistory.sublist(lo, hi).fold(0.0, (s, e) => s + e.bpm)
          / (hi - lo);
      if (i < _smoothedBpms.length) {
        _smoothedBpms[i] = avg;
      } else {
        _smoothedBpms.add(avg);
      }
    }
  }

  // Public read-only view for the chart and tests.
  List<double> get smoothedBpms => List.unmodifiable(_smoothedBpms);

  @visibleForTesting
  List<double> get smoothedBpmsForTest => List.from(_smoothedBpms);

  Future<void> _fetchRecentHRV() async {
    final data = await _workout.getRecentHRV();
    if (data != null) {
      recentHrvMs = (data['ms'] as num?)?.toDouble();
      hrvSource = data['source'] as String?;
      final epochSecs = (data['timestamp'] as num?)?.toDouble();
      recentHrvDate = epochSecs != null
          ? DateTime.fromMillisecondsSinceEpoch((epochSecs * 1000).round())
          : null;
      _safeNotify();
    }
  }

  Future<void> _fetchRestingHR() async {
    final data = await _workout.getRestingHR();
    if (data != null) {
      recentRestingHrBpm = (data['bpm'] as num?)?.toDouble();
      restingHrSource = data['source'] as String?;
      final epochSecs = (data['timestamp'] as num?)?.toDouble();
      recentRestingHrDate = epochSecs != null
          ? DateTime.fromMillisecondsSinceEpoch((epochSecs * 1000).round())
          : null;
      _safeNotify();
    }
  }

  Future<void> _fetchVO2Max() async {
    final data = await _workout.getVO2Max();
    if (data != null) {
      recentVo2MaxMlPerKgMin = (data['mlPerKgMin'] as num?)?.toDouble();
      final epochSecs = (data['timestamp'] as num?)?.toDouble();
      recentVo2MaxDate = epochSecs != null
          ? DateTime.fromMillisecondsSinceEpoch((epochSecs * 1000).round())
          : null;
      _safeNotify();
    }
  }

  Future<void> _fetchBodyMass() async {
    final data = await _workout.getBodyMass();
    if (data != null) {
      autoBodyMassKg = (data['kg'] as num?)?.toDouble();
      final epochSecs = (data['timestamp'] as num?)?.toDouble();
      autoBodyMassDate = epochSecs != null
          ? DateTime.fromMillisecondsSinceEpoch((epochSecs * 1000).round())
          : null;
      _safeNotify();
    }
  }

  /// Manually re-read everything we pull from HealthKit — the Apple Watch
  /// metrics (HRV, resting HR, VO₂ max, body mass) plus the health profile
  /// (age/sex/zones). Same reads as launch, but on an explicit user tap, so a
  /// user looking at a stale value (e.g. a months-old VO₂ max) can force a fresh
  /// read without relaunching. The tap is an explicit "use Apple Health" intent,
  /// so it also clears manual overrides that Apple Health can fill (the metric
  /// reverts to Auto). Uses its own [healthRefreshPending] /
  /// [healthRefreshError] so it can show progress and surface a denied-access
  /// message without disturbing the authorize-access section.
  Future<void> refreshHealthData() async {
    healthRefreshPending = true;
    healthRefreshError = null;
    notifyListeners();

    final authorized = await _workout.requestAuthorization();
    if (!authorized) {
      healthRefreshPending = false;
      healthRefreshError = 'Health access denied. Enable in Settings → Privacy → Health → SteadyHeartBeat.';
      notifyListeners();
      return;
    }

    await _tryFetchHealthProfile();
    await _fetchRecentHRV();
    await _fetchRestingHR();
    await _fetchVO2Max();
    await _fetchBodyMass();

    // An explicit Refresh tap signifies intent: "use Apple Health now." So adopt
    // the freshly-read values by dropping any manual override that Apple Health can
    // replace — the metric reverts to Auto and shows the Apple Health value (rather
    // than the manual value silently masking the refresh). Where Apple Health has
    // nothing, the manual override stays, so we never wipe the user's only number
    // (e.g. a VO₂ max typed in from another watch when Apple Health has none).
    if (recentHrvMs != null) manualHrvMs = null;
    if (recentRestingHrBpm != null) manualRestingHr = null;
    if (recentVo2MaxMlPerKgMin != null) manualVo2Max = null;
    if (autoBodyMassKg != null) manualWeightKg = null;
    await _saveHealthProfile();

    healthRefreshPending = false;
    notifyListeners();
  }

  /// Persists ALL personal health data — age, sex, self-reported conditions,
  /// manual biometric overrides, and the derived HR zones — to the
  /// backup-excluded [HealthProfileStore], NOT shared_preferences (which is
  /// included in iCloud/iTunes backups). Null fields are omitted so a cleared
  /// value (e.g. age) doesn't leave stale zones to be reloaded next launch.
  /// Returns true if the write to the excluded store landed — callers use this
  /// to decide whether the legacy backed-up copy can be safely dropped.
  Future<bool> _saveHealthProfile() async {
    final data = <String, dynamic>{
      'healthConditions': healthConditions.toList(),
      'dangerZoneThreshold': dangerZoneThreshold,
    };
    void putInt(String k, int? v) { if (v != null) data[k] = v; }
    void putDouble(String k, double? v) { if (v != null) data[k] = v; }
    void putString(String k, String? v) { if (v != null) data[k] = v; }
    putInt('manualAge', manualAge);
    putInt('healthAge', healthAge);
    putInt('maxHeartRate', maxHeartRate);
    putInt('zone1End', zone1End);
    putInt('zone2Start', zone2Start);
    putInt('zone3Start', zone3Start);
    putInt('zone4Start', zone4Start);
    putInt('zone5Start', zone5Start);
    putDouble('manualHrv', manualHrvMs);
    putDouble('manualVo2Max', manualVo2Max);
    putDouble('manualRestingHr', manualRestingHr);
    putDouble('manualWeight', manualWeightKg);
    putString('manualSex', manualSex);
    putString('healthSex', healthSex);
    return HealthProfileStore.save(data);
  }

  /// Strips legacy health keys from shared_preferences. Runs once at launch
  /// after the data has been migrated into [HealthProfileStore], so existing
  /// installs stop leaving health data in the backed-up NSUserDefaults plist.
  /// Idempotent — keys already gone are no-ops.
  static const _legacyHealthPrefKeys = [
    'manualAge', 'manualSex', 'healthSex', 'healthConditions',
    'manualHrv', 'manualVo2Max', 'manualRestingHr', 'manualWeight',
    'healthAge', 'maxHeartRate',
    'zone1End', 'zone2Start', 'zone3Start', 'zone4Start', 'zone5Start',
    'dangerZoneThreshold',
  ];
  Future<void> _stripLegacyHealthPrefs(SharedPreferences prefs) async {
    for (final k in _legacyHealthPrefKeys) {
      if (prefs.containsKey(k)) await prefs.remove(k);
    }
  }

  /// Wipes everything the app stores on-device: the workout session history and
  /// the health profile (age, sex, conditions, manual metrics, derived zones).
  /// App settings (voice, units, intervals) are intentionally kept — they aren't
  /// health data. Resets the in-memory health state to its first-launch defaults
  /// so the UI reflects the wipe immediately. Returns the number of sessions
  /// deleted. (HealthKit-derived metrics that mirror Apple Health may re-populate
  /// from the user's own Health data on the next read — that store is theirs, not
  /// ours, and isn't touched here.)
  Future<int> clearAllData() async {
    final removed = await SessionStorageService.deleteAll();
    await HealthProfileStore.clear();
    final prefs = await SharedPreferences.getInstance();
    await _stripLegacyHealthPrefs(prefs); // defensive: drop any un-migrated copies

    healthConditions = {};
    dangerZoneThreshold = kDefaultDangerBpm;
    manualAge = null;
    manualSex = null;
    healthSex = null;
    healthAge = null;
    maxHeartRate = null;
    zone1End = zone2Start = zone3Start = zone4Start = zone5Start = null;
    manualHrvMs = null;
    manualVo2Max = null;
    manualRestingHr = null;
    manualWeightKg = null;
    sessionCount = 0;
    _safeNotify();
    return removed;
  }

  /// Re-reads the number of stored sessions into [sessionCount] and notifies,
  /// so the Export / Delete-All buttons enable/disable correctly.
  Future<void> refreshSessionCount() async {
    sessionCount = await SessionStorageService.count();
    _safeNotify();
  }

  // ── Apple Health workout import ───────────────────────────────────────────

  /// Workouts stored in Apple Health for the import picker, newest first.
  /// Returns null when HealthKit access is denied (so the screen can show a
  /// Settings hint instead of an empty list). Duration filtering is the
  /// screen's job — the full list comes back so the threshold control
  /// re-filters without another HealthKit query.
  Future<List<HealthWorkout>?> listHealthWorkouts() async {
    final authorized = await _workout.requestAuthorization();
    if (!authorized) return null;
    final raw = await _workout.listHealthWorkouts();
    return raw.map(HealthWorkout.fromMap).toList();
  }

  /// End-times (epoch seconds, rounded) of all sessions already on disk —
  /// used to mark Apple Health workouts that are already saved locally so
  /// they can't be imported twice.
  Future<Set<int>> existingSessionEndEpochs() async {
    final sessions = await SessionStorageService.loadAll();
    final out = <int>{};
    for (final s in sessions) {
      final raw = s['endTime'] as String?;
      if (raw == null) continue;
      try {
        out.add(DateTime.parse(raw).millisecondsSinceEpoch ~/ 1000);
      } catch (_) {}
    }
    return out;
  }

  /// Imports [selected] Apple Health workouts as local sessions: fetches each
  /// workout's HR samples, rebuilds the session record (current profile zones
  /// are snapshotted, same as a live save), and writes it to session storage.
  /// Returns (imported, skipped) — a workout with fewer than 2 HR samples has
  /// no timeline to rebuild and is skipped.
  Future<(int, int)> importHealthWorkouts(List<HealthWorkout> selected) async {
    var imported = 0, skipped = 0;
    for (final w in selected) {
      final series = await _workout.getHeartRateSeries(
        startEpoch: w.start.millisecondsSinceEpoch / 1000,
        endEpoch: w.end.millisecondsSinceEpoch / 1000,
      );
      final session = HealthImportService.buildSession(
        workout: w,
        hrTimeline: series,
        zone1End: zone1End,
        zone2Start: zone2Start,
        zone3Start: zone3Start,
        zone4Start: zone4Start,
        zone5Start: zone5Start,
        maxHeartRate: maxHeartRate,
        age: healthAge,
      );
      if (session == null) {
        skipped++;
        continue;
      }
      if (await SessionStorageService.save(session)) {
        imported++;
      } else {
        skipped++;
      }
    }
    await refreshSessionCount();
    return (imported, skipped);
  }

  Future<void> start() async {
    state = MonitoringState.starting;
    errorMessage = null;
    errorSteps = [];
    currentBpm = null;
    currentKcal = null;
    currentRespiratoryRate = null;
    currentSteps = null;
    currentDistanceMeters = null;
    currentFloorsClimbed = null;
    currentAscentMeters = 0;
    _latestBpm = null;
    _deltaBpmBaseline = null;
    _firstSampleAnnounced = false;
    bpmHistory.clear();
    _smoothedBpms.clear();
    _sessionStart = null;
    sessionStart = null;
    sessionEnd = null;
    _lastInProgressSaveAt = null;
    summaryMaxBpm = summaryMinBpm = summaryAvgBpm = summaryEffortPct = null;
    summaryDuration = null;
    summaryHistogram = null;
    summaryZoneSecs = null;
    // Health zone data is preserved and refreshed from HealthKit below
    notifyListeners();

    try {
      await _beginWorkout();
    } catch (e) {
      // A platform-channel call threw (e.g. a native FlutterError from
      // requestAuthorization / startWorkout, or a MissingPluginException)
      // rather than returning a failure value. Route it to the same error UI
      // instead of leaving the spinner stuck on `starting`.
      _setError('Something went wrong starting the workout.', [
        'Close the app completely: swipe up from the bottom and swipe the app away.',
        'Reopen SteadyHeartBeat and try again.',
        'If it keeps failing, restart your iPhone.',
      ]);
    }
  }

  /// The async start sequence: authorization, health profile, AirPods routing,
  /// the native workout session, stream subscriptions, and timers. Split out
  /// from [start] so a thrown platform-channel error is caught there and shown
  /// as an error state rather than surfacing as an unhandled async exception.
  Future<void> _beginWorkout() async {
    // Check authorization
    final authorized = await _workout.requestAuthorization();
    if (!authorized) {
      _setError('Health access denied.', [
        'Open Settings on your iPhone.',
        'Tap Privacy & Security → Health.',
        'Tap SteadyHeartBeat and enable all permissions.',
        'Come back and tap Start Monitoring again.',
      ]);
      return;
    }

    // Pull age-based HR zones from HealthKit DOB.
    final profile = await _workout.getHealthProfile();
    if (profile != null && profile['available'] == true) {
      healthAge = profile['age'] as int?;
      maxHeartRate = profile['maxHeartRate'] as int?;
      zone1End = profile['zone1End'] as int?;
      zone2Start = profile['zone2Start'] as int?;
      zone3Start = profile['zone3Start'] as int?;
      zone4Start = profile['zone4Start'] as int?;
      zone5Start = profile['zone5Start'] as int?;
      if (zone5Start != null) dangerZoneThreshold = zone5Start!;
      zonesWarning = null;
      notifyListeners();
      _saveHealthProfile(); // fire-and-forget
    } else if (maxHeartRate == null) {
      // No DOB available AND we don't have cached zones from a prior session —
      // warn the user that effort %, zone time, and the danger threshold will
      // be unavailable for this workout.
      zonesWarning = 'Heart rate zones disabled — add your date of birth in the Health app to enable.';
      notifyListeners();
    }

    // Check AirPods
    final info = await _workout.checkAirPods();
    airPodsConnected = info['connected'] as bool? ?? false;
    final activeOnThisDevice = info['activeOnThisDevice'] as bool? ?? true;
    airPodsName = info['name'] as String? ?? '';

    if (!activeOnThisDevice) {
      // Don't bounce the user to a dialog yet — and don't trust the passive
      // "not found" read either: freshly-inserted AirPods often aren't in the
      // audio route until something plays. Producing audio on this device pulls
      // the AirPods route — and the HR binding that follows it — over here (the
      // same effect as the user manually starting Music). This speaks
      // "Connecting to your AirPods…" and polls for a few seconds, which also
      // rescues buds the idle check missed. Only error if it still can't reach
      // them.
      final bound = await _workout.bindAirPods();
      if (!bound) {
        if (!airPodsConnected) {
          _setError('AirPods not found!', [
            'Make sure your AirPods are in your ears.',
            'Put them back in the case, close the lid, count to 10, then open and put them in again.',
            'Swipe down from the top-right of your screen and check that Bluetooth is on.',
            'Go to Settings → [your AirPods name] → Heart Rate and make sure it\'s turned on.',
            'Check that both buds are charged — below 20% and some features stop working.',
          ]);
        } else {
          // Connected but we couldn't make them the active output here — most
          // often still in the case / not in your ears, not "owned" by a Mac
          // (paired-elsewhere buds don't show up here at all).
          _setError('AirPods aren\'t active on this iPhone.', [
            'Take your AirPods out of the case and put them in your ears.',
            'If they\'re playing on a Mac or iPad, pause audio or disconnect them there.',
            'Or open Music on this iPhone and play a song — that pulls them over.',
            'Check Bluetooth is on and both buds are charged.',
          ]);
        }
        return;
      }
    }
    notifyListeners();

    // Reset live round state and push the boxing config BEFORE startWorkout —
    // native launches the round timer inside startWorkout (boxing only) and
    // reads this config, so it must arrive first.
    roundPhase = 'done';
    currentRound = 0;
    roundTotal = 0;
    roundRemaining = 0;
    _pushBoxingConfig();
    plus.onWorkoutStart();

    // Push the save-to-Health choice before the session ends. The native
    // singleton defaults to "save", so re-pushing here ensures a relaunch with
    // the toggle off still discards rather than persisting the workout.
    _workout.setSaveToHealth(saveToHealth);

    // Push the unit preference so the spoken ascent cue ("Climbed N feet/meters")
    // matches the display. Re-pushed each start for a fresh native singleton.
    _workout.setUseImperial(useImperial);

    // Start native workout session. The announce interval is passed in so the
    // native periodic timer starts at the chosen cadence from the first tick.
    final started = await _workout.startWorkout(
      workoutType: selectedWorkoutType.hkKey,
      announceIntervalSeconds: announceIntervalSeconds,
    );
    if (!started) {
      _setError('Couldn\'t start the workout session.', [
        'Close the app completely: swipe up from the bottom and swipe the app away.',
        'Reopen SteadyHeartBeat and try again.',
        'If it keeps failing, restart your iPhone.',
      ]);
      return;
    }

    // Subscribe to HR and status streams
    _hrSub = _workout.heartRateStream.listen(_onHeartRate, onError: _onStreamError);
    _statusSub = _workout.statusStream.listen(_onStatus, onError: _onStreamError);

    // Hand the native announce path the zone boundaries + coaching settings so
    // it can name the zone (and nudge toward a target) even while backgrounded.
    _pushZoneConfig();

    // If no data arrives within 15 seconds, show error
    _noDataTimer = Timer(const Duration(seconds: kNoDataTimeoutSeconds), () {
      if (currentBpm == null && state == MonitoringState.running) {
        _setError('Heart rate not detected.', [
          'AirPods Pro 3 (or newer) are required — earlier AirPods don\'t have the sensor.',
          'If you have AirPods Pro 3: check your ear tip size. Try the next size up for a snugger fit — the sensor is on the tip, not the stem.',
          'Dry your ears — moisture or earwax can block the optical sensor.',
          'Go to Settings → [your AirPods name] → Heart Rate and make sure it\'s turned on.',
          'Take one earbud out and reseat it firmly.',
          'Give it 15 seconds — the sensor takes a moment to lock on.',
        ]);
      }
    });

    state = MonitoringState.running;
    _stopIdlePoll();
    WakelockPlus.enable(); // keep screen on during workout
    _scheduleDim();
    notifyListeners();
    // The periodic announce is driven natively (iOS suspends the Dart isolate in
    // the background) and its cadence was already set via startWorkout above.
  }

  void _onHeartRate(Map<String, dynamic> data) {
    final bpm = (data['bpm'] as num?)?.toDouble();
    final kcal = (data['kcal'] as num?)?.toDouble();
    final rr = (data['respiratoryRate'] as num?)?.toDouble();

    if (kcal != null && kcal > 0) currentKcal = kcal;
    if (rr != null && rr > 0) currentRespiratoryRate = rr;
    final steps = (data['steps'] as num?)?.toDouble();
    final dist  = (data['distanceMeters'] as num?)?.toDouble();
    final floors = (data['floorsClimbed'] as num?)?.toDouble();
    if (steps != null && steps > 0) currentSteps = steps;
    if (dist  != null && dist  > 0) currentDistanceMeters = dist;
    if (floors != null && floors > 0) currentFloorsClimbed = floors;
    final ascent = (data['ascentMeters'] as num?)?.toDouble();
    if (ascent != null && ascent > 0) currentAscentMeters = ascent;
    if (bpm == null || bpm <= 0) {
      // Altimeter-only payloads carry no BPM — still refresh the UI so the
      // elevation readout updates between heart-rate samples.
      if (ascent != null) notifyListeners();
      return;
    }
    // Filter physiologically implausible samples — sensor glitches outside
    // [kHrMinBpm, kHrMaxBpm] would otherwise corrupt min/max/zone-time math.
    if (bpm < kHrMinBpm || bpm > kHrMaxBpm) {
      // Debug-only: keeps live BPM values out of release device logs.
      if (kDebugMode) {
        debugPrint('WorkoutProvider: dropping out-of-range HR sample: $bpm');
      }
      return;
    }

    if (_sessionStart == null) {
      _sessionStart = DateTime.now();
      sessionStart = _sessionStart;
    }
    final elapsed = DateTime.now().difference(_sessionStart!).inMilliseconds / 1000.0;
    bpmHistory.add(BpmSample(elapsed, bpm));
    _updateSmoothedBpms();

    _latestBpm = bpm;
    currentBpm = bpm;
    _noDataTimer?.cancel();
    // Watch for mid-workout HR-stream silence (AirPods drop, ear-tip lost
    // contact). Rearmed on every sample; the callback below fires only if no
    // sample arrives for kHrSilenceTimeoutSeconds.
    _armHrSilenceTimer();
    // Crash-recovery snapshot — every HR sample updates the file so the user
    // loses at most one sample's worth of data if the app is killed mid-workout.
    _saveInProgress();
    notifyListeners();

    // Opening reading: speak it immediately, regardless of the delta toggle or
    // interval, so the workout starts with an actual BPM right after the spoken
    // start confirmation. Seed the delta baseline so the block below doesn't
    // double-announce the same sample.
    if (!_firstSampleAnnounced) {
      _firstSampleAnnounced = true;
      _deltaBpmBaseline = bpm;
      _announce(bpm);
      return;
    }

    // Announce on significant change — compares against delta baseline,
    // which is independent of the interval timer so gradual drift is caught.
    // (Foreground only — native owns the periodic announce in background.)
    final baseline = _deltaBpmBaseline;
    if (deltaAnnounceEnabled && (baseline == null || (bpm - baseline).abs() >= deltaThreshold)) {
      _deltaBpmBaseline = bpm;
      _announce(bpm);
    }
  }

  Future<void> _onStatus(Map<String, dynamic> data) async {
    final type = data['type'] as String?;
    final value = data['value'] as String?;
    if (type == 'round') {
      // Live boxing round state from the native round timer (the source of
      // truth — a Dart timer would stall when backgrounded).
      roundPhase = data['phase'] as String? ?? 'done';
      currentRound = data['round'] as int? ?? 0;
      roundTotal = data['total'] as int? ?? 0;
      roundRemaining = data['remaining'] as int? ?? 0;
      // The SHB+ module reads its own fields from the event (no-op in the
      // free core).
      plus.onRoundEvent(data);
      notifyListeners();
      return;
    }
    if (type == 'error') {
      _setError(value ?? 'Unknown error from heart rate sensor.');
    } else if (type == 'state' && value == 'backgrounded') {
      // Native (WorkoutManager.swift) speaks the confirmation directly because
      // the Dart isolate may already be paused at this point.
    } else if (type == 'state' && value == 'stopped') {
      // HealthKit ended the session from the native side (background kill,
      // iOS timeout, etc.). Mirror the same cleanup that stop() does, but
      // skip stopWorkout() — the session is already gone.
      if (state == MonitoringState.running) {
        _cancelTimers();
        _hrSub?.cancel();
        _statusSub?.cancel();
        WakelockPlus.disable();
        _tts.stop();
        if (bpmHistory.length >= 2 && _sessionStart != null) {
          sessionEnd ??= DateTime.now();
          _computeSummary();
          await _persistSession();
        }
        state = MonitoringState.stopped;
        _startIdlePoll();
        notifyListeners();
      }
    }
  }

  void _onStreamError(Object error) {
    _setError(error.toString());
  }

  void _announce(double bpm) {
    _tts.speak('${bpm.round()}');
  }

  /// Immediate spoken feedback after an announcement-related preference change
  /// (interval, voice, delta, zone coaching): speaks the current BPM through
  /// the forced path, which bypasses the native BPM cooldown — the change
  /// usually lands seconds after a regular announcement, exactly when the
  /// cooldown would otherwise swallow it.
  void _announcePrefChange() {
    final bpm = currentBpm;
    if (bpm != null && state == MonitoringState.running) {
      _tts.speak('${bpm.round()}', force: true);
    }
  }

  /// (Re)schedules the mid-workout HR-silence detector. Called from
  /// _onHeartRate on every sample so the timer is continuously pushed out.
  /// If it ever fires, we drop the stale BPM, speak a one-shot alert, and
  /// notify the UI — but we do NOT stop the workout, because the signal
  /// usually returns shortly when the user re-seats the AirPods.
  void _armHrSilenceTimer() {
    _hrSilenceTimer?.cancel();
    _hrSilenceTimer = Timer(const Duration(seconds: kHrSilenceTimeoutSeconds), () {
      if (state != MonitoringState.running) return;
      currentBpm = null;
      _latestBpm = null;
      _tts.speak('Heart rate signal lost');
      _safeNotify();
    });
  }

  Future<void> stop() async {
    _cancelTimers();
    // Compute summary while bpmHistory is still intact, then persist.
    if (bpmHistory.length >= 2 && _sessionStart != null) {
      sessionEnd = DateTime.now();
      _computeSummary();
      await _persistSession();
    }
    await _hrSub?.cancel();
    await _statusSub?.cancel();
    await _workout.stopWorkout();
    await _tts.stop();
    WakelockPlus.disable();
    state = MonitoringState.stopped;
    _startIdlePoll();
    notifyListeners();
  }

  void _computeSummary() {
    final bpms = bpmHistory.map((s) => s.bpm).toList();
    summaryMaxBpm = bpms.reduce(max);
    summaryMinBpm = bpms.reduce(min);
    summaryDuration = sessionEnd!.difference(_sessionStart!);

    // Time-weighted average BPM and histogram (trapezoidal)
    double totalSecs = 0, weightedSum = 0;
    final hist = <int, double>{};
    for (int i = 1; i < bpmHistory.length; i++) {
      final dt = bpmHistory[i].secondsFromStart - bpmHistory[i - 1].secondsFromStart;
      final avg = (bpmHistory[i].bpm + bpmHistory[i - 1].bpm) / 2;
      totalSecs += dt;
      weightedSum += avg * dt;
      final bin = avg.round();
      hist[bin] = (hist[bin] ?? 0) + dt;
    }
    summaryAvgBpm = totalSecs > 0 ? weightedSum / totalSecs : bpms.first;
    summaryHistogram = hist;

    if (maxHeartRate != null && maxHeartRate! > 0 && summaryAvgBpm != null) {
      summaryEffortPct = (summaryAvgBpm! / maxHeartRate!) * 100;
    }

    // Compute zone-time distribution once — _ZoneTimeLine reads this instead
    // of iterating bpmHistory on every build (O(1) vs O(n)).
    if (zone1End != null && zone2Start != null && zone3Start != null &&
        zone4Start != null && zone5Start != null) {
      const brady = kBradycardiaThreshold;
      final z1 = zone1End!.toDouble();
      final z2 = zone2Start!.toDouble();
      final z3 = zone3Start!.toDouble();
      final z4 = zone4Start!.toDouble();
      final secs = List.filled(6, 0.0);
      for (int i = 1; i < bpmHistory.length; i++) {
        final dt  = bpmHistory[i].secondsFromStart - bpmHistory[i - 1].secondsFromStart;
        final bpm = (bpmHistory[i].bpm + bpmHistory[i - 1].bpm) / 2;
        final idx = bpm < brady ? 0 : bpm < z1 ? 1 : bpm < z2 ? 2
                  : bpm < z3   ? 3 : bpm < z4   ? 4 : 5;
        secs[idx] += dt;
      }
      summaryZoneSecs = List.unmodifiable(secs);
    }
  }

  /// Builds the JSON map for the current session. Used by both the final
  /// persist and the in-progress snapshot. `endTime` is required for the
  /// final save (it's the session id); for in-progress snapshots pass the
  /// most recent HR sample's wall-clock time.
  Map<String, dynamic> _buildSessionMap({required DateTime endTime}) {
    final zoneSecs = summaryZoneSecs?.toList() ?? List.filled(6, 0.0);
    return {
      'id':              endTime.toIso8601String(),
      'workoutType':     selectedWorkoutType.hkKey,
      'startTime':       (_sessionStart ?? endTime).toIso8601String(),
      'endTime':         endTime.toIso8601String(),
      'durationSeconds': summaryDuration?.inSeconds ?? 0,
      'deviceName':      airPodsName,
      'maxBpm':          summaryMaxBpm,
      'avgBpm':          summaryAvgBpm,
      'minBpm':          summaryMinBpm,
      'kcal':            currentKcal,
      'respiratoryRate': currentRespiratoryRate,
      'steps':           currentSteps?.round(),
      'distanceMeters':  currentDistanceMeters,
      'floorsClimbed':   currentFloorsClimbed?.round(),
      'effortPct':       summaryEffortPct,
      'zoneSecs':        zoneSecs,
      // JSON requires string keys in maps
      'histogram':       summaryHistogram?.map((k, v) => MapEntry('$k', v)),
      'hrTimeline':      bpmHistory.map((s) => [s.secondsFromStart, s.bpm]).toList(),
      // Zone config snapshot used during this session
      'zone1End':        zone1End,
      'zone2Start':      zone2Start,
      'zone3Start':      zone3Start,
      'zone4Start':      zone4Start,
      'zone5Start':      zone5Start,
      'maxHeartRate':    maxHeartRate,
      'age':             healthAge,
    };
  }

  Future<void> _persistSession() async {
    if (_sessionStart == null || sessionEnd == null) return;
    final ok = await SessionStorageService.save(
      _buildSessionMap(endTime: sessionEnd!),
    );
    if (ok) {
      // Final save succeeded → drop the crash-recovery snapshot.
      await SessionStorageService.clearInProgress();
      saveError = null;
    } else {
      // Surface to UI; the snapshot is left behind so the user can recover on
      // next launch even if this final write failed.
      saveError = 'Could not save the workout to disk. The session is still in the recovery file and will reload on next launch.';
    }
    _safeNotify();
  }

  /// If a prior run left an in-progress snapshot (app killed, OOM, force-quit),
  /// compute a summary from the recorded HR timeline and save it as a regular
  /// session. Discards snapshots with fewer than 2 samples (no meaningful data).
  Future<void> _recoverOrphanSession() async {
    final snap = await SessionStorageService.loadInProgress();
    if (snap == null) return;

    final timeline = (snap['hrTimeline'] as List?) ?? [];
    if (timeline.length < 2) {
      await SessionStorageService.clearInProgress();
      return;
    }

    final samples = timeline.map((e) {
      final list = e as List;
      return BpmSample((list[0] as num).toDouble(), (list[1] as num).toDouble());
    }).toList();
    final bpms = samples.map((s) => s.bpm).toList();

    // Time-weighted avg and histogram (trapezoidal — same as _computeSummary).
    double totalSecs = 0, weightedSum = 0;
    final hist = <int, double>{};
    for (int i = 1; i < samples.length; i++) {
      final dt = samples[i].secondsFromStart - samples[i - 1].secondsFromStart;
      final avg = (samples[i].bpm + samples[i - 1].bpm) / 2;
      totalSecs += dt;
      weightedSum += avg * dt;
      final bin = avg.round();
      hist[bin] = (hist[bin] ?? 0) + dt;
    }
    final avgBpm = totalSecs > 0 ? weightedSum / totalSecs : bpms.first;

    // Zone-time distribution from the snapshot's zone config.
    final z1 = (snap['zone1End'] as num?)?.toDouble();
    final z2 = (snap['zone2Start'] as num?)?.toDouble();
    final z3 = (snap['zone3Start'] as num?)?.toDouble();
    final z4 = (snap['zone4Start'] as num?)?.toDouble();
    final zoneSecs = List<double>.filled(6, 0.0);
    if (z1 != null && z2 != null && z3 != null && z4 != null) {
      const brady = kBradycardiaThreshold;
      for (int i = 1; i < samples.length; i++) {
        final dt = samples[i].secondsFromStart - samples[i - 1].secondsFromStart;
        final b = (samples[i].bpm + samples[i - 1].bpm) / 2;
        final idx = b < brady ? 0 : b < z1 ? 1 : b < z2 ? 2 : b < z3 ? 3 : b < z4 ? 4 : 5;
        zoneSecs[idx] += dt;
      }
    }

    final maxHr = (snap['maxHeartRate'] as num?)?.toInt();
    final effort = (maxHr != null && maxHr > 0) ? (avgBpm / maxHr) * 100 : null;
    final start = DateTime.parse(snap['startTime'] as String);
    final end   = DateTime.parse(snap['endTime'] as String);

    final finalSession = Map<String, dynamic>.from(snap)
      ..['durationSeconds'] = end.difference(start).inSeconds
      ..['maxBpm']    = bpms.reduce(max)
      ..['minBpm']    = bpms.reduce(min)
      ..['avgBpm']    = avgBpm
      ..['effortPct'] = effort
      ..['zoneSecs']  = zoneSecs
      ..['histogram'] = hist.map((k, v) => MapEntry('$k', v));

    final ok = await SessionStorageService.save(finalSession);
    if (ok) {
      await SessionStorageService.clearInProgress();
      // Debug-only: keeps recovered-session details out of release device logs.
      if (kDebugMode) {
        debugPrint('Recovered orphan session: ${samples.length} samples, ${end.difference(start).inSeconds}s');
      }
    }
  }

  DateTime? _lastInProgressSaveAt;
  static const _inProgressSaveCooldown = Duration(seconds: 30);

  /// Writes a crash-recovery snapshot of the in-progress session. Called from
  /// _onHeartRate so every HR sample updates the snapshot — worst-case data
  /// loss on app kill is ~30 s. We throttle (rather than save per sample)
  /// because the snapshot serializes the entire bpmHistory: at AirPods Pro 3
  /// sample rate (~5 s) a 2-hour workout would otherwise do ~1400 disk writes
  /// of progressively larger JSON.
  void _saveInProgress() {
    if (_sessionStart == null || bpmHistory.isEmpty) return;
    final now = DateTime.now();
    if (_lastInProgressSaveAt != null &&
        now.difference(_lastInProgressSaveAt!) < _inProgressSaveCooldown) {
      return;
    }
    _lastInProgressSaveAt = now;
    // No summary yet — pass the most recent sample's wall-clock time as
    // endTime so the snapshot has a defined id/duration.
    final endTime = _sessionStart!.add(
      Duration(milliseconds: (bpmHistory.last.secondsFromStart * 1000).round()),
    );
    SessionStorageService.saveInProgress(
      _buildSessionMap(endTime: endTime),
    );
  }

  void _setError(String message, [List<String> steps = const []]) {
    _cancelTimers();
    _hrSub?.cancel();
    _statusSub?.cancel();
    // End any native workout that already started before the error (e.g. the
    // no-data timeout fires AFTER startWorkout()). Without this the
    // HKWorkoutSession + audio session leak, and a subsequent start() would
    // create a second session without ending the first. Null-safe natively
    // when no session is live, so it's harmless on the pre-start error paths.
    _workout.stopWorkout();
    WakelockPlus.disable();
    state = MonitoringState.error;
    errorMessage = message;
    errorSteps = steps;
    _startIdlePoll();
    notifyListeners();
  }

  void _scheduleDim() {
    _dimTimer?.cancel();
    _dimTimer = Timer(const Duration(minutes: 1), () => WakelockPlus.disable());
  }

  void onScreenTap() {
    if (state != MonitoringState.running) return;
    WakelockPlus.enable();
    _scheduleDim();
  }

  void _cancelTimers() {
    _noDataTimer?.cancel();
    _hrSilenceTimer?.cancel();
    _dimTimer?.cancel();
  }

  /// Selects the announce voice. [identifier] null = automatic (best available).
  /// [name] is stored only for display in Preferences. Persists, pushes the
  /// choice to native, and re-announces the current BPM if a workout is live.
  Future<void> setVoice(String? identifier, {String? name}) async {
    voiceIdentifier = identifier;
    voiceName = name;
    notifyListeners();
    await savePrefs();
    _announcePrefChange();
  }

  /// English voices installed on this iPhone, best quality first (for the picker).
  Future<List<Map<String, dynamic>>> availableVoices() => _workout.listVoices();

  /// The voice the announce path actually resolves to right now — including the
  /// auto-selected best voice when none is chosen. Lets the picker highlight it.
  Future<String> resolvedVoiceIdentifier() => _workout.currentVoiceIdentifier();

  /// Plays a spoken sample of [identifier] (empty = automatic) for the picker.
  Future<void> previewVoice(String identifier, {String? text}) =>
      _workout.previewVoice(identifier, text: text);

  Future<void> setAnnounceInterval(int seconds) async {
    announceIntervalSeconds = seconds;
    notifyListeners();
    await savePrefs();
    if (state == MonitoringState.running) {
      // Awaited so back-to-back changes go through the MethodChannel in order;
      // without await the futures could be issued out of order if the caller
      // rapidly toggles the picker.
      await _workout.setAnnounceInterval(seconds);
      _announcePrefChange();
    }
  }

  void setDeltaAnnounceEnabled(bool enabled) {
    deltaAnnounceEnabled = enabled;
    notifyListeners();
    savePrefs();
    _announcePrefChange();
  }

  void setWelcomeEnabled(bool enabled) {
    welcomeEnabled = enabled;
    notifyListeners();
    savePrefs();
  }

  /// When true, a finished workout is written to Apple Health (counting toward
  /// the Apple Fitness rings, and following the user's iCloud Health sync). When
  /// false the native layer discards it at stop, so the workout never leaves the
  /// device. The flag is consulted natively at workout stop; push it now so a
  /// mid-workout toggle takes effect, and it's also re-pushed at every start.
  void setSaveToHealth(bool enabled) {
    saveToHealth = enabled;
    notifyListeners();
    savePrefs();
    _workout.setSaveToHealth(enabled);
  }

  void setZoneCoachingEnabled(bool enabled) {
    zoneCoachingEnabled = enabled;
    notifyListeners();
    savePrefs();
    if (state == MonitoringState.running) _pushZoneConfig();
    // Channel calls are FIFO, so the forced announce lands after the new zone
    // config and speaks with the new coaching setting applied.
    _announcePrefChange();
  }

  /// Target training zone for coaching nudges: 0 = none (just name the zone),
  /// 1–5 = steer toward that zone with "push" / "ease off".
  void setTargetZone(int zone) {
    targetZone = zone.clamp(0, 5);
    notifyListeners();
    savePrefs();
    if (state == MonitoringState.running) _pushZoneConfig();
    _announcePrefChange();
  }

  /// Pushes the current zone boundaries + coaching settings to native. Called at
  /// workout start (once zones are resolved) and whenever a coaching setting
  /// changes mid-workout. Boundaries are sent only when all five are known.
  void _pushZoneConfig() {
    final b = [zone1End, zone2Start, zone3Start, zone4Start, zone5Start];
    if (b.every((e) => e != null)) {
      _workout.setZones(b.cast<int>());
    }
    // Zone coaching is a cycling-only feature — its only UI lives in the cycling
    // pre-workout sheet. The enabled/target prefs persist globally, so suppress
    // them for every other workout type; otherwise picking e.g. Walking would
    // still hear "below zone 1, push" from a config set during a cycling session.
    final coaching =
        zoneCoachingEnabled && selectedWorkoutType == WorkoutType.cycling;
    _workout.setZoneCoaching(
      enabled: coaching,
      targetZone: coaching ? targetZone : 0,
    );
  }

  // ── Boxing round timer settings ──────────────────────────────────────────

  void setBoxingRoundsEnabled(bool enabled) {
    boxingRoundsEnabled = enabled;
    notifyListeners();
    savePrefs();
  }

  /// Round/rest lengths in seconds; round count (0 = unlimited).
  void setRoundSecs(int secs) {
    roundSecs = secs.clamp(60, 300);
    notifyListeners();
    savePrefs();
  }

  void setRestSecs(int secs) {
    restSecs = secs.clamp(0, 120);
    notifyListeners();
    savePrefs();
  }

  void setTotalRounds(int rounds) {
    totalRounds = rounds.clamp(0, 15);
    notifyListeners();
    savePrefs();
  }

  void setRoundWarnEnabled(bool enabled) {
    roundWarnEnabled = enabled;
    notifyListeners();
    savePrefs();
  }

  /// One-tap preset: sets round/rest lengths and round count together.
  void applyBoxingPreset({required int rounds, required int round, required int rest}) {
    totalRounds = rounds.clamp(0, 15);
    roundSecs = round.clamp(60, 300);
    restSecs = rest.clamp(0, 120);
    notifyListeners();
    savePrefs();
  }


  /// Pushes boxing round config to native. Called once before the native
  /// workout starts (the round timer is launched inside startWorkout), so the
  /// config must arrive first.
  void _pushBoxingConfig() {
    _workout.setBoxingRounds(
      enabled: boxingRoundsEnabled,
      roundSecs: roundSecs,
      restSecs: restSecs,
      totalRounds: totalRounds,
      warnSecs: roundWarnEnabled ? 10 : 0,
      prepSecs: 10,
    );
  }

  void setDeltaThreshold(int bpm) {
    deltaThreshold = bpm;
    notifyListeners();
    savePrefs();
    _announcePrefChange();
  }

  void setWorkoutType(WorkoutType type) {
    selectedWorkoutType = type;
    notifyListeners();
    savePrefs();
  }

  /// Deletes the just-finished session from disk, then resets to idle.
  /// Used by the "Discard" button on the post-workout summary screen — the
  /// session was already persisted by stop() (or by the native 'stopped'
  /// status), so undoing requires an explicit delete by id.
  Future<void> discardCurrentSession() async {
    if (sessionEnd != null) {
      await SessionStorageService.delete(sessionEnd!.toIso8601String());
    }
    resetToIdle();
  }

  void resetToIdle() {
    state = MonitoringState.idle;
    errorMessage = null;
    errorSteps = [];
    currentBpm = null;
    currentKcal = null;
    currentRespiratoryRate = null;
    currentSteps = null;
    currentDistanceMeters = null;
    currentFloorsClimbed = null;
    currentAscentMeters = 0;
    _latestBpm = null;
    _deltaBpmBaseline = null;
    _firstSampleAnnounced = false;
    bpmHistory.clear();
    _smoothedBpms.clear();
    _sessionStart = null;
    sessionStart = null;
    sessionEnd = null;
    _lastInProgressSaveAt = null;
    summaryMaxBpm = summaryMinBpm = summaryAvgBpm = summaryEffortPct = null;
    summaryDuration = null;
    summaryHistogram = null;
    summaryZoneSecs = null;
    notifyListeners();
  }

  void setHealthConditions(Set<String> conditions) {
    healthConditions = conditions;
    notifyListeners();
    _saveHealthProfile();
  }

  void setUseImperial(bool v) {
    useImperial = v;
    notifyListeners();
    savePrefs();
    // Keep native in sync so a units change mid-workout reaches the ascent cue.
    _workout.setUseImperial(v);
  }

  void clearSaveError() {
    saveError = null;
    _safeNotify();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _cancelTimers();
    _stopIdlePoll();
    _hrSub?.cancel();
    _statusSub?.cancel();
    _tts.dispose();
    super.dispose();
  }

  /// notifyListeners() that no-ops after dispose. Several startup paths
  /// (_loadPrefs, _recoverOrphanSession, the unawaited health fetches) can
  /// resolve after the provider is disposed — without this guard they trip
  /// ChangeNotifier's "used after disposed" assertion.
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }
}
