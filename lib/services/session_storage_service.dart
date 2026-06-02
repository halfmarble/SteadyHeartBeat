import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'backup_exclusion.dart';

/// Persists completed workout sessions as JSON files in the app's Documents
/// directory. Each file is named after the session end timestamp.
/// These records are the raw material for future opt-in research data sharing.
///
/// Crash-recovery: while a workout is running, the provider periodically calls
/// [saveInProgress] to write a snapshot to `in_progress.json`. On clean stop
/// the snapshot is removed; if the app dies before clean stop, the next launch
/// finds the snapshot via [loadInProgress] and finalises it as a regular
/// session so the user doesn't lose their workout.
class SessionStorageService {
  static const _inProgressFilename = 'in_progress.json';

  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/sessions');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // The session JSON holds workout health data — keep it off device backups.
    await BackupExclusion.ensureExcluded(dir);
    return dir;
  }

  /// Returns true if the session was written, false on any I/O error so the
  /// caller can surface a "session not saved" alert.
  static Future<bool> save(Map<String, dynamic> session) async {
    try {
      final dir = await _dir();
      // Sanitise the ISO timestamp for use as a filename
      final id = (session['id'] as String).replaceAll(':', '-').replaceAll('.', '-');
      await File('${dir.path}/$id.json').writeAsString(jsonEncode(session));
      return true;
    } catch (e) {
      debugPrint('SessionStorageService.save: $e');
      return false;
    }
  }

  /// Writes the in-progress workout snapshot. Overwrites any prior snapshot
  /// (one workout in flight at a time). Silently fails — losing one snapshot
  /// is recoverable on the next call; we'd rather drop the snapshot than crash
  /// the workout flow.
  static Future<void> saveInProgress(Map<String, dynamic> session) async {
    try {
      final dir = await _dir();
      await File('${dir.path}/$_inProgressFilename').writeAsString(jsonEncode(session));
    } catch (e) {
      debugPrint('SessionStorageService.saveInProgress: $e');
    }
  }

  /// Returns the orphaned in-progress snapshot if one exists. Null otherwise.
  static Future<Map<String, dynamic>?> loadInProgress() async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/$_inProgressFilename');
      if (!file.existsSync()) return null;
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('SessionStorageService.loadInProgress: $e');
      return null;
    }
  }

  static Future<void> clearInProgress() async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/$_inProgressFilename');
      if (file.existsSync()) await file.delete();
    } catch (e) {
      debugPrint('SessionStorageService.clearInProgress: $e');
    }
  }

  /// Returns all sessions sorted newest-first.
  static Future<List<Map<String, dynamic>>> loadAll() async {
    try {
      final dir = await _dir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json') &&
                       !f.path.endsWith('/$_inProgressFilename'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));

      final out = <Map<String, dynamic>>[];
      for (final f in files) {
        try {
          out.add(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
        } catch (e) {
          debugPrint('SessionStorageService.loadAll (parse): $e');
        }
      }
      return out;
    } catch (e) {
      debugPrint('SessionStorageService.loadAll: $e');
      return [];
    }
  }

  static Future<void> delete(String id) async {
    try {
      final dir = await _dir();
      final sanitized = id.replaceAll(':', '-').replaceAll('.', '-');
      final file = File('${dir.path}/$sanitized.json');
      if (file.existsSync()) await file.delete();
    } catch (e) {
      debugPrint('SessionStorageService.delete: $e');
    }
  }

  static Future<int> count() async {
    try {
      final dir = await _dir();
      return dir.listSync().whereType<File>().where((f) =>
          f.path.endsWith('.json') &&
          !f.path.endsWith('/$_inProgressFilename')).length;
    } catch (e) {
      debugPrint('SessionStorageService.count: $e');
      return 0;
    }
  }
}
