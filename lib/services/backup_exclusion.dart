import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Marks a directory as excluded from iCloud/iTunes backup, so the on-device
/// data it holds never leaves the device. Shared by the file-backed stores
/// ([SessionStorageService], [HealthProfileStore]).
///
/// iOS persists the exclusion flag, but we (re)apply it once per launch per
/// directory so paths created by older builds — which never set it — get
/// covered too. The work is delegated to the native `excludeFromBackup` method
/// channel. Best-effort: a failure is logged and left un-cached so the next
/// call retries.
class BackupExclusion {
  BackupExclusion._();

  static const _channel = MethodChannel('steadyheartbeat/workout');

  /// Paths excluded so far this launch — keyed by path so each distinct
  /// directory is excluded exactly once (a single global flag would wrongly
  /// skip the second directory after the first succeeded).
  static final Set<String> _excluded = {};

  static Future<void> ensureExcluded(Directory dir) async {
    if (_excluded.contains(dir.path)) return;
    try {
      await _channel.invokeMethod('excludeFromBackup', {'path': dir.path});
      _excluded.add(dir.path);
    } catch (e) {
      debugPrint('BackupExclusion.ensureExcluded(${dir.path}): $e');
    }
  }
}
