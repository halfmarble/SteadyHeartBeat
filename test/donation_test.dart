import 'dart:math' show Random;
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_heart_beat/services/donation_service.dart';

// The anonymizer is the only place private data becomes shareable, so these
// pin its guarantees: valid UUIDs, no PII, and — the one that matters for the
// science — timestamps are fuzzed but inter-sample INTERVALS are preserved
// exactly (a constant per-session offset).

Map<String, dynamic> _session(String start, List<List<num>> timeline) => {
      'id': start, // the real-time id; must NOT survive into the donation
      'startTime': start,
      'endTime': start,
      'workoutType': 'boxing',
      'age': 52,
      'healthConditions': ['cardiovascular'],
      'hrTimeline': timeline,
    };

final _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void main() {
  group('uuid4', () {
    test('is a well-formed v4 UUID', () {
      for (var i = 0; i < 50; i++) {
        expect(DonationService.uuid4(Random(i)), matches(_uuidV4));
      }
    });
  });

  group('newSessionOffsetMinutes', () {
    test('stays within ±7 days', () {
      final r = Random(1);
      for (var i = 0; i < 5000; i++) {
        final o = DonationService.newSessionOffsetMinutes(r);
        expect(o, inInclusiveRange(-10080, 10080));
      }
    });
  });

  group('buildDonationBundle', () {
    final sessions = [
      _session('2026-06-01T10:00:00.000', [
        [0, 80],
        [5, 90],
        [10, 100],
      ]),
      _session('2026-06-02T18:30:00.000', [
        [0, 70],
        [30, 120],
      ]),
    ];

    test('emits OBG envelope records with no PII and correct hr_bpm', () {
      final b = DonationService.buildDonationBundle(sessions, rng: Random(7));
      expect(b['format'], 'OpenBioenergyGauge-donation');
      final records = (b['records'] as List).cast<Map<String, dynamic>>();
      expect(records, hasLength(5));
      expect(b['record_count'], 5);

      const forbidden = {
        'age', 'sex', 'healthSex', 'manualSex', 'healthConditions', 'name',
        'email', 'dob', 'latitude', 'longitude', 'id', 'workoutType',
      };
      for (final rec in records) {
        // Envelope present
        expect(rec['schema_version'], DonationService.obgSchemaVersion);
        expect(rec['source'], 'airpods_pro_3');
        expect(rec['placement'], 'other');
        expect(rec['quality'], 0.5);
        expect(rec['user_id'], matches(_uuidV4));
        expect(rec['session_id'], matches(_uuidV4));
        expect(rec['hr_bpm'], isA<int>());
        // No PII / identifying fields
        for (final k in forbidden) {
          expect(rec.containsKey(k), isFalse, reason: '"$k" must not be in a record');
        }
      }
      // hr_bpm round-trips the input series
      expect(records.map((r) => r['hr_bpm']).toList(), [80, 90, 100, 70, 120]);
    });

    test('one donor user_id across the batch; one session_id per workout', () {
      final b = DonationService.buildDonationBundle(sessions, rng: Random(7));
      final records = (b['records'] as List).cast<Map<String, dynamic>>();
      expect(records.map((r) => r['user_id']).toSet(), hasLength(1));
      expect(b['user_id'], records.first['user_id']);
      // two workouts → two distinct session_ids
      expect(records.map((r) => r['session_id']).toSet(), hasLength(2));
    });

    test('INTERVAL FIDELITY: per-session constant offset; deltas preserved', () {
      final b = DonationService.buildDonationBundle(sessions, rng: Random(7));
      final records = (b['records'] as List).cast<Map<String, dynamic>>();

      // Group by session_id, in emission order.
      final bySession = <String, List<Map<String, dynamic>>>{};
      for (final rec in records) {
        (bySession[rec['session_id'] as String] ??= []).add(rec);
      }
      expect(bySession.length, 2);

      final offsets = <Duration>[];
      bySession.forEach((sid, recs) {
        final realStart = recs.length == 3
            ? DateTime.parse('2026-06-01T10:00:00.000')
            : DateTime.parse('2026-06-02T18:30:00.000');
        final expectedDeltas = recs.length == 3 ? [5, 10] : [30]; // seconds from start
        // Offset = fuzzed first sample minus real first sample.
        final offset = DateTime.parse(recs.first['timestamp'] as String)
            .difference(realStart);
        offsets.add(offset);
        // Every sample shifted by the SAME offset → intervals from start intact.
        for (var i = 0; i < recs.length; i++) {
          final fuzzed = DateTime.parse(recs[i]['timestamp'] as String);
          final realSampleSecs = i == 0 ? 0 : expectedDeltas[i - 1];
          final real = realStart.add(Duration(seconds: realSampleSecs));
          expect(fuzzed.difference(real), offset,
              reason: 'sample $i must carry the same per-session offset');
        }
        // Offset is a whole number of minutes (the fuzz unit).
        expect(offset.inSeconds % 60, 0);
      });

      // Independent offsets per session (so a weekly schedule can't be rebuilt).
      expect(offsets[0], isNot(offsets[1]));
    });

    test('empty input yields an empty record set', () {
      final b = DonationService.buildDonationBundle(const [], rng: Random(7));
      expect(b['record_count'], 0);
      expect(b['records'], isEmpty);
    });
  });
}
