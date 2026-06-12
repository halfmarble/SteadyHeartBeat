import 'package:flutter_test/flutter_test.dart';
import 'package:steady_heart_beat/services/health_import_service.dart';

HealthWorkout _workout({
  String type = 'boxing',
  DateTime? start,
  DateTime? end,
  double? kcal,
  double? distanceMeters,
  String source = 'Test Watch',
}) {
  final s = start ?? DateTime(2026, 6, 1, 10, 0, 0);
  final e = end ?? s.add(const Duration(minutes: 30));
  return HealthWorkout(
    type: type,
    start: s,
    end: e,
    durationSeconds: e.difference(s).inSeconds.toDouble(),
    kcal: kcal,
    distanceMeters: distanceMeters,
    source: source,
  );
}

void main() {
  group('HealthWorkout.fromMap', () {
    test('parses epochs, duration, and optional fields', () {
      final w = HealthWorkout.fromMap({
        'type': 'cycling',
        'startEpoch': 1000000000.0,
        'endEpoch': 1000001800.0,
        'durationSeconds': 1800.0,
        'kcal': 250.5,
        'source': 'Apple Watch',
      });
      expect(w.type, 'cycling');
      expect(w.end.difference(w.start).inSeconds, 1800);
      expect(w.durationSeconds, 1800);
      expect(w.kcal, 250.5);
      expect(w.distanceMeters, isNull);
      expect(w.source, 'Apple Watch');
    });

    test('defaults missing fields safely', () {
      final w = HealthWorkout.fromMap(const {});
      expect(w.type, 'other');
      expect(w.durationSeconds, 0);
      expect(w.source, '');
    });
  });

  group('HealthImportService.buildSession', () {
    test('returns null for fewer than 2 HR samples', () {
      expect(
        HealthImportService.buildSession(workout: _workout(), hrTimeline: []),
        isNull,
      );
      expect(
        HealthImportService.buildSession(
            workout: _workout(), hrTimeline: [[0.0, 100.0]]),
        isNull,
      );
    });

    test('rebuilds id/times/type/device from the workout', () {
      final start = DateTime(2026, 6, 1, 10, 0, 0);
      final end = DateTime(2026, 6, 1, 10, 30, 0);
      final s = HealthImportService.buildSession(
        workout: _workout(start: start, end: end, kcal: 300, source: 'Watch X'),
        hrTimeline: [
          [0.0, 100.0],
          [60.0, 110.0],
        ],
      )!;
      expect(s['id'], end.toIso8601String());
      expect(s['startTime'], start.toIso8601String());
      expect(s['endTime'], end.toIso8601String());
      expect(s['durationSeconds'], 1800);
      expect(s['workoutType'], 'boxing');
      expect(s['deviceName'], 'Watch X');
      expect(s['kcal'], 300);
      expect(s['importedFrom'], 'apple_health');
    });

    test('computes time-weighted avg, min/max, and histogram', () {
      // Two segments: 100→120 over 10s (avg 110), 120→120 over 30s (avg 120).
      final s = HealthImportService.buildSession(
        workout: _workout(),
        hrTimeline: [
          [0.0, 100.0],
          [10.0, 120.0],
          [40.0, 120.0],
        ],
      )!;
      expect(s['maxBpm'], 120.0);
      expect(s['minBpm'], 100.0);
      // (110×10 + 120×30) / 40 = 117.5
      expect(s['avgBpm'], closeTo(117.5, 0.001));
      final hist = s['histogram'] as Map;
      expect(hist['110'], 10.0);
      expect(hist['120'], 30.0);
    });

    test('zone seconds bucket against the provided zone config', () {
      // Zones: z1End 100, z2 110, z3 120, z4 130. Segment avgs: 105 (zone 2,
      // 60s) and 125 (zone 4, 60s).
      final s = HealthImportService.buildSession(
        workout: _workout(),
        hrTimeline: [
          [0.0, 100.0],
          [60.0, 110.0],
          [120.0, 140.0],
        ],
        zone1End: 100,
        zone2Start: 110,
        zone3Start: 120,
        zone4Start: 130,
        zone5Start: 140,
        maxHeartRate: 170,
        age: 55,
      )!;
      final zones = s['zoneSecs'] as List<double>;
      expect(zones[2], 60.0); // 105 avg → zone 2
      expect(zones[4], 60.0); // 125 avg → zone 4
      expect(s['zone5Start'], 140);
      expect(s['maxHeartRate'], 170);
      expect(s['age'], 55);
      // effort = avg/maxHR×100; avg = (105×60 + 125×60)/120 = 115
      expect(s['effortPct'], closeTo(115 / 170 * 100, 0.001));
    });

    test('zones absent → zeroed zoneSecs and null effort', () {
      final s = HealthImportService.buildSession(
        workout: _workout(),
        hrTimeline: [
          [0.0, 100.0],
          [60.0, 110.0],
        ],
      )!;
      expect((s['zoneSecs'] as List<double>).every((v) => v == 0), isTrue);
      expect(s['effortPct'], isNull);
    });
  });
}
