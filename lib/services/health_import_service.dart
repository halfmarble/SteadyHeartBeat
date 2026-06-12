import '../constants.dart';

/// One workout as listed from Apple Health for the import picker.
class HealthWorkout {
  final String type; // app workout-type key: boxing/cycling/running/walking/hiking/other
  final DateTime start;
  final DateTime end;
  final double durationSeconds;
  final double? kcal;
  final double? distanceMeters;
  final String source; // e.g. "SteadyHeartBeat", "Gerard's Apple Watch"

  const HealthWorkout({
    required this.type,
    required this.start,
    required this.end,
    required this.durationSeconds,
    this.kcal,
    this.distanceMeters,
    required this.source,
  });

  factory HealthWorkout.fromMap(Map<String, dynamic> m) {
    DateTime fromEpoch(dynamic secs) => DateTime.fromMillisecondsSinceEpoch(
        (((secs as num?)?.toDouble() ?? 0) * 1000).round());
    return HealthWorkout(
      type: m['type'] as String? ?? 'other',
      start: fromEpoch(m['startEpoch']),
      end: fromEpoch(m['endEpoch']),
      durationSeconds: (m['durationSeconds'] as num?)?.toDouble() ?? 0,
      kcal: (m['kcal'] as num?)?.toDouble(),
      distanceMeters: (m['distanceMeters'] as num?)?.toDouble(),
      source: m['source'] as String? ?? '',
    );
  }
}

/// Rebuilds app session records from Apple Health workouts — the recovery path
/// for session files lost from local storage (every finished workout the app
/// saves to Apple Health carries the HR samples needed to reconstruct one).
///
/// Glass Box: the summary math here (time-weighted trapezoidal average,
/// histogram, zone seconds) mirrors WorkoutProvider._computeSummary /
/// _recoverOrphanSession exactly, so an imported session is indistinguishable
/// from one recorded live.
class HealthImportService {
  /// Builds the session JSON map for [workout] from its [hrTimeline]
  /// ([secondsFromStart, bpm] pairs, ascending). Returns null when the
  /// timeline has fewer than 2 samples — there is no meaningful session to
  /// rebuild without a heart-rate line.
  ///
  /// The zone snapshot fields come from the caller's CURRENT profile (same as
  /// a live session, which snapshots the zones in effect at save time).
  static Map<String, dynamic>? buildSession({
    required HealthWorkout workout,
    required List<List<double>> hrTimeline,
    int? zone1End,
    int? zone2Start,
    int? zone3Start,
    int? zone4Start,
    int? zone5Start,
    int? maxHeartRate,
    int? age,
  }) {
    if (hrTimeline.length < 2) return null;

    final bpms = hrTimeline.map((p) => p[1]).toList();

    // Time-weighted average BPM and histogram (trapezoidal — matches
    // WorkoutProvider._computeSummary).
    double totalSecs = 0, weightedSum = 0;
    final hist = <int, double>{};
    for (int i = 1; i < hrTimeline.length; i++) {
      final dt = hrTimeline[i][0] - hrTimeline[i - 1][0];
      final avg = (hrTimeline[i][1] + hrTimeline[i - 1][1]) / 2;
      totalSecs += dt;
      weightedSum += avg * dt;
      final bin = avg.round();
      hist[bin] = (hist[bin] ?? 0) + dt;
    }
    final avgBpm = totalSecs > 0 ? weightedSum / totalSecs : bpms.first;

    // Zone-time distribution from the caller's zone config.
    final zoneSecs = List<double>.filled(6, 0.0);
    if (zone1End != null &&
        zone2Start != null &&
        zone3Start != null &&
        zone4Start != null) {
      final z1 = zone1End.toDouble();
      final z2 = zone2Start.toDouble();
      final z3 = zone3Start.toDouble();
      final z4 = zone4Start.toDouble();
      const brady = kBradycardiaThreshold;
      for (int i = 1; i < hrTimeline.length; i++) {
        final dt = hrTimeline[i][0] - hrTimeline[i - 1][0];
        final b = (hrTimeline[i][1] + hrTimeline[i - 1][1]) / 2;
        final idx = b < brady ? 0 : b < z1 ? 1 : b < z2 ? 2 : b < z3 ? 3 : b < z4 ? 4 : 5;
        zoneSecs[idx] += dt;
      }
    }

    double maxBpm = bpms.first, minBpm = bpms.first;
    for (final b in bpms) {
      if (b > maxBpm) maxBpm = b;
      if (b < minBpm) minBpm = b;
    }
    final effort = (maxHeartRate != null && maxHeartRate > 0)
        ? (avgBpm / maxHeartRate) * 100
        : null;

    return {
      'id': workout.end.toIso8601String(),
      'workoutType': workout.type,
      'startTime': workout.start.toIso8601String(),
      'endTime': workout.end.toIso8601String(),
      'durationSeconds': workout.end.difference(workout.start).inSeconds,
      'deviceName': workout.source,
      'maxBpm': maxBpm,
      'avgBpm': avgBpm,
      'minBpm': minBpm,
      'kcal': workout.kcal,
      'respiratoryRate': null,
      'steps': null,
      'distanceMeters': workout.distanceMeters,
      'floorsClimbed': null,
      'effortPct': effort,
      'zoneSecs': zoneSecs,
      'histogram': hist.map((k, v) => MapEntry('$k', v)),
      'hrTimeline': hrTimeline,
      'zone1End': zone1End,
      'zone2Start': zone2Start,
      'zone3Start': zone3Start,
      'zone4Start': zone4Start,
      'zone5Start': zone5Start,
      'maxHeartRate': maxHeartRate,
      'age': age,
      // Provenance marker so an imported session is distinguishable from one
      // recorded live (research donations and exports carry it through).
      'importedFrom': 'apple_health',
    };
  }
}
