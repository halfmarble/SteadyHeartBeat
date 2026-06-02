import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'backup_exclusion.dart';

/// On-device store for the user's personal health data — age, biological sex,
/// self-reported conditions, manual biometric overrides (HRV / VO₂max / resting
/// HR / weight), and the derived HR zones.
///
/// This data is deliberately kept OUT of `shared_preferences`: on iOS that maps
/// to NSUserDefaults, which is included in iCloud/iTunes device backups. Here it
/// lives in a single JSON file under a directory we mark excluded-from-backup
/// (the same native `excludeFromBackup` channel the session store uses), so the
/// health data never leaves the device. App settings (voice, intervals, units…)
/// stay in shared_preferences — they're not health data.
class HealthProfileStore {
  static const _filename = 'health_profile.json';

  /// The file lives in a dedicated `private/` subdirectory (NOT `sessions/`,
  /// whose `*.json` files are enumerated as workout sessions).
  static Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/private');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // Personal health data — keep it off device backups.
    await BackupExclusion.ensureExcluded(dir);
    return File('${dir.path}/$_filename');
  }

  /// Returns the stored health map, or an empty map if none exists yet.
  static Future<Map<String, dynamic>> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return {};
      final raw = await f.readAsString();
      if (raw.isEmpty) return {};
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('HealthProfileStore.load: $e');
      return {};
    }
  }

  /// Overwrites the stored health map. Returns true on success. A write failure
  /// is logged and returns false so the caller can decide whether it's safe to
  /// drop the legacy backed-up copy — the in-memory values remain authoritative
  /// for the session, and the next save retries.
  static Future<bool> save(Map<String, dynamic> data) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(data));
      return true;
    } catch (e) {
      debugPrint('HealthProfileStore.save: $e');
      return false;
    }
  }
}
