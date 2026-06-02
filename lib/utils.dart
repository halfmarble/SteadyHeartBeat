String fmtDist(double m, bool imperial) {
  if (imperial) {
    final miles = m / 1609.344;
    if (miles < 0.1) return '${(m * 3.28084).round()} ft';
    return '${miles.toStringAsFixed(2)} mi';
  }
  return m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(2)} km';
}

String fmtSteps(double s) =>
    s < 1000 ? s.round().toString() : '${(s / 1000).toStringAsFixed(1)}k';

/// Formats an ascent/elevation value (meters in → m or ft out). Stays in m/ft —
/// ascent totals live in the tens-to-thousands range, so no km/mi conversion.
String fmtElevation(double m, bool imperial) =>
    imperial ? '${(m * 3.28084).round()} ft' : '${m.round()} m';

/// Formats an elapsed workout duration. Under an hour: M:SS (e.g. 5:03). One
/// hour or more: H:MM:SS (e.g. 1:05:03) — the hours digit only appears once the
/// duration crosses 60 minutes, so short workouts stay compact.
String fmtDuration(int totalSeconds) {
  final secs = totalSeconds < 0 ? 0 : totalSeconds;
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  final s = secs % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) {
    final mm = m.toString().padLeft(2, '0');
    return '$h:$mm:$ss';
  }
  return '$m:$ss';
}
