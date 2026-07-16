import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// Scans the USER-FACING copy (string literals in the UI layer) for language
// that would break the FDA General Wellness positioning (revised January
// 2026): no treat/cure/mitigate/prevent/diagnose claims and no brand-name
// medications, anywhere a user can read it. Complements
// metric_explainer_test.dart, which covers only kMetricExplainers.
//
// The scan reads the source files, skips comment lines, extracts
// single-quoted string literals, and checks each against the banned list. A
// short allowlist strips the legitimate negation disclaimers ("not a …
// diagnosis") before matching.
void main() {
  test('user-facing string literals avoid FDA-restricted language', () {
    final dirs = [
      Directory('lib/screens'),
      Directory('lib/widgets'),
      Directory('lib/providers'), // SnackBar / error / warning copy
      Directory('lib/services'),  // export notices etc.
      Directory('lib/plus'), // absent in the public export — guarded below
    ];
    final files = <File>[
      for (final d in dirs)
        if (d.existsSync())
          ...d.listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
    ];
    expect(files, isNotEmpty, reason: 'scan found no UI sources — wrong cwd?');

    // Negation disclaimers that may legitimately contain a banned stem.
    final allow = [
      RegExp(r'not a [^.]*diagnosis', caseSensitive: false),
    ];
    final banned = RegExp(
      r'\b(treats?|treating|treatment|cures?|curing|'
      r'diagnose[sd]?|diagnosing|diagnosis|diagnostic\w*|'
      r'mitigat\w*|prevent\w*|sinemet)\b',
      caseSensitive: false,
    );
    // Both Dart string forms — double quotes are what authors reach for when
    // the copy itself contains an apostrophe.
    final literals = [
      RegExp(r"'((?:[^'\\]|\\.)*)'"),
      RegExp(r'"((?:[^"\\]|\\.)*)"'),
    ];

    final failures = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trimLeft();
        if (trimmed.startsWith('//')) continue;
        for (final m in literals.expand((r) => r.allMatches(lines[i]))) {
          var text = m.group(1)!;
          if (text.startsWith('package:') || text.startsWith('http')) continue;
          for (final a in allow) {
            text = text.replaceAll(a, '');
          }
          final hit = banned.firstMatch(text);
          if (hit != null) {
            failures.add(
                '${f.path}:${i + 1}: banned "${hit.group(0)}" in: $text');
          }
        }
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
