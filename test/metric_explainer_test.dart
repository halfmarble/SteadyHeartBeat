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

    test('every readiness explainer carries at least one cited source', () {
      for (final k in ['bedHrv', 'restingHrv', 'bedHr', 'restingHr', 'vo2max']) {
        expect(kMetricExplainers[k]!.sources, isNotEmpty,
            reason: '$k has no sources');
      }
    });

    test('resting-HR explainers cite the Quer 2020 reference source', () {
      for (final k in ['bedHr', 'restingHr']) {
        final labels =
            kMetricExplainers[k]!.sources.map((s) => s.label).join(' ').toLowerCase();
        expect(labels, contains('quer'),
            reason: '$k should cite the Quer 2020 resting-HR reference');
      }
    });
  });

  group('referenceRange (text fallback)', () {
    test('age-banded metrics need an age, sex-banded do not', () {
      // HRV / VO₂max are age-banded → null without age.
      expect(referenceRange('bedHrv'), isNull);
      expect(referenceRange('vo2max'), isNull);
      expect(referenceRange('bedHrv', age: 50), isNotNull);
      expect(referenceRange('vo2max', age: 50), isNotNull);
      // Resting HR is sex-banded only → available without age.
      expect(referenceRange('restingHr'), isNotNull);
    });

    test('unknown key yields no range', () {
      expect(referenceRange('steps', age: 50), isNull);
    });
  });

  group('gaugeSpec', () {
    test('null without a value, even with age/sex', () {
      expect(gaugeSpec('restingHr', age: 50, female: false), isNull);
      expect(gaugeSpec('bedHrv', age: 50, value: 0), isNull); // non-positive
    });

    test('resting HR plots the Quer band, women above men', () {
      final m = gaugeSpec('restingHr', female: false, value: 58)!;
      final f = gaugeSpec('restingHr', female: true, value: 58)!;
      expect(m.unit, 'bpm');
      expect((m.lo, m.hi), (50.0, 80.0));
      expect((f.lo, f.hi), (53.0, 82.0));
      expect(m.value, 58);
    });

    test('axis brackets the band (axisMin <= lo < hi <= axisMax)', () {
      final specs = [
        gaugeSpec('bedHrv', age: 45, value: 40)!,
        gaugeSpec('restingHr', age: 45, female: true, value: 60)!,
        gaugeSpec('vo2max', age: 45, female: false, value: 38)!,
      ];
      for (final s in specs) {
        expect(s.axisMin, lessThanOrEqualTo(s.lo));
        expect(s.lo, lessThan(s.hi));
        expect(s.hi, lessThanOrEqualTo(s.axisMax));
        expect(s.axisMax, greaterThan(s.axisMin));
      }
    });

    test('age-banded gauges still need an age', () {
      expect(gaugeSpec('bedHrv', value: 40), isNull);
      expect(gaugeSpec('vo2max', value: 40), isNull);
    });
  });
}
