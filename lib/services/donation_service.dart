import 'dart:convert';
import 'dart:math' show Random;
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'export_service.dart';
import 'session_storage_service.dart';

/// Builds an **anonymized**, OpenBioenergyGauge-shaped copy of the user's
/// workout heart-rate data, for optional, manual donation to research.
///
/// This is the in-app port of OBG's `TheTimestamp-FuzzingPipeline.py` anonymizer
/// (the only place private data is turned into something shareable). The shield:
///   1. **No PII leaves.** SteadyHeartBeat never stores name/email/DOB/GPS, and
///      this export deliberately omits age, sex, conditions, and the real-time
///      session ids — only an anonymized heart-rate time series is emitted.
///   2. **UUIDs, not identities.** A fresh random donor `user_id` is generated per
///      export; each workout gets its own random `session_id`. Both are v4 UUIDs
///      from a cryptographic RNG — unlinkable to the user or across exports.
///   3. **±7-day timestamp fuzz.** Each session's timeline is shifted by one
///      uniform random offset in ±7 days (NOT ±24 h, which would leave the real
///      bedtime as a recurring pattern). The offset is constant within a session,
///      so inter-sample intervals — the only thing the algorithm consumes — are
///      preserved exactly; different sessions get independent offsets so a weekly
///      schedule can't be reconstructed.
///
/// Honest limitation, surfaced in the bundle: AirPods Pro 3 give beats-per-minute,
/// not R-R intervals, so this contributes an `hr_bpm` series — below OBG Level 1
/// "Core" (which wants `rr_ms`) — the bundle says so rather than implying a
/// fidelity it does not have.
class DonationService {
  /// OBG Conformance schema version this export targets (Conformance.md §4, draft).
  static const obgSchemaVersion = '0.1.0';
  static const sevenDaysInMinutes = 7 * 24 * 60; // 10080
  static const _source = 'airpods_pro_3';
  static const _placement = 'other'; // in-ear isn't in the OBG placement enum
  static const _quality = 0.5; // no independent SQI → the §4.1.1 default anchor

  /// One uniform fuzz offset in [-7 days, +7 days], in minutes. Drawn once per
  /// session and applied to every sample in it (mirrors `new_session_offset_minutes`).
  static int newSessionOffsetMinutes(Random rng) =>
      rng.nextInt(2 * sevenDaysInMinutes + 1) - sevenDaysInMinutes;

  /// A v4 UUID from [rng]. Use a cryptographic RNG (Random.secure()) in prod.
  static String uuid4(Random rng) {
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
        '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
  }

  /// Turns one stored session into OBG envelope records (one per HR sample),
  /// anonymized: real timestamps fuzzed by [offsetMinutes], tagged with the
  /// anonymous [userId]/[sessionId]. Returns [] if the session has no usable
  /// timeline or start time.
  static List<Map<String, dynamic>> anonymizeSession(
    Map<String, dynamic> session, {
    required String userId,
    required String sessionId,
    required int offsetMinutes,
  }) {
    final startRaw = session['startTime'] as String?;
    final timeline = session['hrTimeline'] as List?;
    if (startRaw == null || timeline == null) return const [];
    final DateTime start;
    try {
      start = DateTime.parse(startRaw);
    } catch (_) {
      return const [];
    }
    final fuzz = Duration(minutes: offsetMinutes);
    final out = <Map<String, dynamic>>[];
    for (final e in timeline) {
      if (e is! List || e.length < 2) continue;
      final secs = (e[0] as num).toDouble();
      final bpm = (e[1] as num);
      // real sample time → fuzzed → UTC ISO-8601 (ms precision per §4.1).
      final t = start
          .add(Duration(milliseconds: (secs * 1000).round()))
          .add(fuzz)
          .toUtc();
      out.add({
        'schema_version': obgSchemaVersion,
        'user_id': userId,
        'session_id': sessionId,
        'source': _source,
        'placement': _placement,
        'timestamp': t.toIso8601String(),
        'quality': _quality,
        'hr_bpm': bpm.round(),
      });
    }
    return out;
  }

  /// Assembles the full anonymized donation bundle from [sessions]. [rng] is
  /// injectable for deterministic tests (default: a cryptographic RNG).
  static Map<String, dynamic> buildDonationBundle(
    List<Map<String, dynamic>> sessions, {
    Random? rng,
  }) {
    final r = rng ?? Random.secure();
    final userId = uuid4(r); // one donor UUID for this batch, unlinkable elsewhere
    final records = <Map<String, dynamic>>[];
    for (final session in sessions) {
      records.addAll(anonymizeSession(
        session,
        userId: userId,
        sessionId: uuid4(r), // fresh per workout
        offsetMinutes: newSessionOffsetMinutes(r), // independent per workout
      ));
    }
    return {
      'format': 'OpenBioenergyGauge-donation',
      'schema_version': obgSchemaVersion,
      'generatedBy': 'SteadyHeartBeat',
      'anonymization': {
        'user_id': 'random v4 UUID (per export); per-session random session_id',
        'pii': 'none included — no name/email/DOB/GPS stored; age/sex/conditions omitted',
        'timestamp_fuzz_minutes': '±$sevenDaysInMinutes (uniform per session; intervals preserved)',
        'note':
            'Heart-rate (hr_bpm) time series only. AirPods Pro 3 provide BPM, not '
            'R-R intervals, so this is below OBG Level 1 Core (which expects rr_ms).',
      },
      'user_id': userId,
      'record_count': records.length,
      'records': records,
    };
  }

  /// Builds the anonymized bundle from all stored sessions and presents the
  /// share sheet so the user can hand the file to the research program. Returns
  /// null on success, `'empty'` if there are no sessions to donate, or a
  /// step-tagged error string.
  static Future<String?> shareDonation({Rect? origin, Random? rng}) async {
    try {
      final sessions = await SessionStorageService.loadAll();
      if (sessions.isEmpty) return 'empty';
      final bundle = buildDonationBundle(sessions, rng: rng);
      final json = const JsonEncoder.withIndent('  ').convert(bundle);
      final name =
          'SteadyHeartBeat-research-donation-${ExportService.fileStamp(null)}.json';
      return ExportService.shareJsonFile(json, name,
          origin: origin, subject: 'SteadyHeartBeat anonymized research donation');
    } catch (e) {
      debugPrint('DonationService.shareDonation: $e');
      return '[build] $e';
    }
  }
}
