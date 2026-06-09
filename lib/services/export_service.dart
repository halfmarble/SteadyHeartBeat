import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'health_profile_store.dart';
import 'session_storage_service.dart';

/// Builds a portable, plaintext copy of everything the app holds on-device and
/// hands it to the system share sheet so the owner can take their data with them
/// — to the Files app, AirDrop, a backup, or a researcher.
///
/// This is the one place the app deliberately moves data OUT of its protected
/// storage, and only on an explicit user tap. The export is NOT encrypted: the
/// recipient is the data's owner, who already has cleartext access to it inside
/// the app. Handing the owner an encrypted file would either be theatre (we'd
/// ship the key too) or a footgun (a lost passphrase = lost data). For the
/// rationale, and for why donation to OpenBioenergyGauge needs anonymisation
/// rather than encryption, see DATA_PORTABILITY.md.
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
          'This is a complete, unencrypted copy of your SteadyHeartBeat data, '
          'exported at your request. It contains personal health information. '
          'Once saved outside the app it follows your own device/cloud settings '
          '— store it somewhere you trust.',
      'healthProfile': profile,
      'sessionCount': sessions.length,
      'sessions': sessions,
    };
  }

  /// Writes the bundle to a temp file and presents the system share sheet.
  /// Returns false if the file couldn't be written (the caller can surface an
  /// error); a user who dismisses the share sheet is still a success.
  ///
  /// [origin] is the source rect for the iPad popover presentation; harmless to
  /// omit on iPhone.
  static Future<bool> exportToShareSheet({Rect? origin, DateTime? now}) async {
    try {
      final bundle = await buildBundle(now: now);
      final json = const JsonEncoder.withIndent('  ').convert(bundle);
      // A temp file (not the protected store) — it exists only to feed the
      // share sheet and is the user's to keep once shared.
      final dir = await getTemporaryDirectory();
      final stamp = (now ?? DateTime.now())
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final file = File('${dir.path}/SteadyHeartBeat-data-$stamp.json');
      await file.writeAsString(json);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'My SteadyHeartBeat data',
        sharePositionOrigin: origin,
      );
      return true;
    } catch (e) {
      debugPrint('ExportService.exportToShareSheet: $e');
      return false;
    }
  }
}
