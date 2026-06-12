import 'package:flutter_test/flutter_test.dart';
import 'package:steady_heart_beat/widgets/metric_explainer.dart';

void main() {
  group('metric explainers', () {
    test('cover the readiness-snapshot metric keys', () {
      for (final k in ['bedHrv', 'restingHrv', 'bedHr', 'restingHr', 'vo2max']) {
        expect(kMetricExplainers.containsKey(k), isTrue, reason: 'missing $k');
        final e = kMetricExplainers[k]!;
        expect(e.title.trim(), isNotEmpty);
        expect(e.paragraphs, isNotEmpty);
        for (final p in e.paragraphs) {
          expect(p.trim(), isNotEmpty);
        }
      }
    });

    test('avoid FDA-restricted language (General Wellness positioning)', () {
      // Brand/legal constraint: never connect the product to disease treatment.
      const banned = ['treat', 'cure', 'diagnose', 'prevent', 'mitigate'];
      for (final e in kMetricExplainers.values) {
        final text = e.paragraphs.join(' ').toLowerCase();
        for (final w in banned) {
          expect(text.contains(w), isFalse,
              reason: '"${e.title}" copy contains banned word "$w"');
        }
      }
    });

    test('every explainer closes with the wellness, not-medical caveat', () {
      for (final e in kMetricExplainers.values) {
        expect(e.paragraphs.last.toLowerCase(), contains('not a medical'),
            reason: '${e.title} missing the wellness caveat');
      }
    });
  });
}
