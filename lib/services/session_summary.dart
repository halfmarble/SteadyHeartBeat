import '../constants.dart';

/// The derived summary of one heart-rate timeline.
///
/// One implementation for all three producers of a session record — the live
/// stop path (WorkoutProvider._computeSummary), crash recovery
/// (WorkoutProvider._recoverOrphanSession), and the Apple Health import
/// (HealthImportService.buildSession). These previously carried three
/// hand-mirrored copies of this math with "must mirror exactly" comments; a
/// fix applied to one and not the others would make recovered/imported
/// sessions silently diverge from live ones.
class HrSummary {
  final double maxBpm;
  final double minBpm;
  final double avgBpm;

  /// Trapezoidal time-in-bin histogram, keyed by the rounded segment-average
  /// BPM.
  final Map<int, double> histogram;

  /// Seconds in [below-bradycardia, zone1..zone5]; null when the zone config
  /// is incomplete (callers decide between null and a zero-filled list).
  final List<double>? zoneSecs;

  /// Time-weighted average as % of max HR; null when max HR is unknown.
  final double? effortPct;

  const HrSummary({
    required this.maxBpm,
    required this.minBpm,
    required this.avgBpm,
    required this.histogram,
    required this.zoneSecs,
    required this.effortPct,
  });
}

/// Time-weighted (trapezoidal) summary of an HR timeline of
/// `[secondsFromStart, bpm]` pairs, ascending. Requires at least 2 samples —
/// callers gate on that before building a session record.
HrSummary summarizeHrTimeline(
  List<List<double>> hrTimeline, {
  double? zone1End,
  double? zone2Start,
  double? zone3Start,
  double? zone4Start,
  int? maxHeartRate,
}) {
  assert(hrTimeline.length >= 2, 'a session summary needs >= 2 HR samples');

  double maxBpm = hrTimeline.first[1], minBpm = hrTimeline.first[1];
  for (final p in hrTimeline) {
    if (p[1] > maxBpm) maxBpm = p[1];
    if (p[1] < minBpm) minBpm = p[1];
  }

  final haveZones = zone1End != null &&
      zone2Start != null &&
      zone3Start != null &&
      zone4Start != null;
  const brady = kBradycardiaThreshold;

  double totalSecs = 0, weightedSum = 0;
  final hist = <int, double>{};
  final secs = List<double>.filled(6, 0.0);
  for (int i = 1; i < hrTimeline.length; i++) {
    final dt = hrTimeline[i][0] - hrTimeline[i - 1][0];
    final avg = (hrTimeline[i][1] + hrTimeline[i - 1][1]) / 2;
    totalSecs += dt;
    weightedSum += avg * dt;
    final bin = avg.round();
    hist[bin] = (hist[bin] ?? 0) + dt;
    if (haveZones) {
      final idx = avg < brady
          ? 0
          : avg < zone1End
              ? 1
              : avg < zone2Start
                  ? 2
                  : avg < zone3Start
                      ? 3
                      : avg < zone4Start
                          ? 4
                          : 5;
      secs[idx] += dt;
    }
  }
  final avgBpm = totalSecs > 0 ? weightedSum / totalSecs : hrTimeline.first[1];

  return HrSummary(
    maxBpm: maxBpm,
    minBpm: minBpm,
    avgBpm: avgBpm,
    histogram: hist,
    zoneSecs: haveZones ? secs : null,
    effortPct: (maxHeartRate != null && maxHeartRate > 0)
        ? (avgBpm / maxHeartRate) * 100
        : null,
  );
}
