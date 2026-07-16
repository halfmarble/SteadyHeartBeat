import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'health_profile_store.dart';
import 'session_storage_service.dart';

/// Builds a portable copy of everything the app holds on-device and hands it to
/// the system share sheet so the owner can take their data with them — to the
/// Files app, AirDrop, a backup, or a researcher.
///
/// This is the one place the app deliberately moves data OUT of its protected
/// storage, and only on an explicit user tap. The export is plaintext JSON: the
/// recipient is the data's owner, who already has cleartext access to it inside
/// the app, so there is nothing for encryption to defend. The owner is trusted
/// to store the file somewhere they trust. For the rationale — and why donating
/// to OpenBioenergyGauge needs anonymisation rather than encryption — see
/// DATA_PORTABILITY.md.
class ExportService {
  /// Bumped if the bundle shape changes, so a consumer can branch on it.
  static const schemaVersion = '1.0';

  /// Assembles the export bundle: a self-describing envelope plus the user's
  /// health profile and every stored session. [now] is injected so the bundle
  /// is deterministic under test.
  static Future<Map<String, dynamic>> buildBundle({DateTime? now}) async {
    final profile = await HealthProfileStore.load();
    final sessions = await SessionStorageService.loadAll();
    return {
      'schemaVersion': schemaVersion,
      'generatedBy': 'SteadyHeartBeat',
      'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'notice':
          'This is a complete copy of your SteadyHeartBeat data, exported at '
          'your request. It contains personal health information. Once saved '
          'outside the app it follows your own device/cloud settings — store it '
          'somewhere you trust.',
      'healthProfile': profile,
      'sessionCount': sessions.length,
      'sessions': sessions,
    };
  }

  /// The bundle as an indented JSON string (the plaintext payload).
  static Future<String> _bundleJson(DateTime? now) async =>
      const JsonEncoder.withIndent('  ').convert(await buildBundle(now: now));

  /// Writes the plaintext bundle to a temp file and presents the system share
  /// sheet. Returns null on success (a user who dismisses the share sheet is
  /// still a success); on failure returns a short error string the caller can
  /// surface, tagged with the step that failed so a field report pinpoints the
  /// cause.
  ///
  /// [origin] is the source rect for the iPad popover presentation; harmless to
  /// omit on iPhone.
  static Future<String?> exportToShareSheet(
      {Rect? origin, DateTime? now}) async {
    var step = 'build';
    try {
      final json = await _bundleJson(now);
      final stamp = fileStamp(now);
      final name = 'SteadyHeartBeat-data-$stamp.json';
      return shareJsonFile(json, name, origin: origin);
    } catch (e) {
      debugPrint('ExportService.exportToShareSheet [$step]: $e');
      return '[$step] $e';
    }
  }

  /// A filename-safe timestamp stamp (colons/dots → dashes).
  static String fileStamp(DateTime? now) => (now ?? DateTime.now())
      .toIso8601String()
      .replaceAll(':', '-')
      .replaceAll('.', '-');

  /// Test seam for the actual share-sheet presentation, so the write → share →
  /// delete flow can be exercised without the platform channel.
  @visibleForTesting
  static Future<void> Function(XFile file, String subject, Rect? origin)
      sharePresenter = _presentShareSheet;

  static Future<void> _presentShareSheet(
      XFile file, String subject, Rect? origin) async {
    await Share.shareXFiles([file], subject: subject, sharePositionOrigin: origin);
  }

  /// Writes [content] to a temp file named [filename] and presents the system
  /// share sheet. Returns null on success (dismissing the sheet still counts) or
  /// a step-tagged error string. Shared by the data export and the research
  /// donation. The temp file only exists for the duration of the share — the
  /// share sheet's recipient takes its own copy, and leaving a plaintext health
  /// export in the tmp dir (which is outside the backup-excluded stores) would
  /// defeat the point of protecting the real ones. [origin] must be a NON-ZERO
  /// rect within the source view — iOS rejects a zero-size sharePositionOrigin
  /// even on iPhone.
  static Future<String?> shareJsonFile(String content, String filename,
      {Rect? origin, String? subject}) async {
    var step = 'tempdir';
    File? file;
    try {
      final dir = await getTemporaryDirectory();
      step = 'write';
      file = File('${dir.path}/$filename');
      await file.writeAsString(content);
      step = 'share';
      await sharePresenter(
        XFile(file.path, mimeType: 'application/json'),
        subject ?? filename,
        origin,
      );
      return null;
    } catch (e) {
      debugPrint('ExportService.shareJsonFile [$step]: $e');
      return '[$step] $e';
    } finally {
      // Best-effort cleanup of the plaintext copy, whether the share succeeded,
      // was dismissed, or threw.
      try {
        if (file != null && file.existsSync()) await file.delete();
      } catch (e) {
        debugPrint('ExportService.shareJsonFile [cleanup]: $e');
      }
    }
  }
}
