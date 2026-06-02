import 'package:flutter_test/flutter_test.dart';
import 'package:steady_heart_beat/health_norms.dart';

void main() {
  group('vo2maxBands', () {
    test('bands are internally ordered excellent > good > fair', () {
      for (final age in [22, 35, 45, 55, 65, 75]) {
        final b = vo2maxBands(age);
        expect(b.excellent, greaterThan(b.good));
        expect(b.good, greaterThan(b.fair));
      }
    });

    test('cutoffs decline (or hold) with age', () {
      int? prevGood;
      for (final age in [25, 35, 45, 55, 65, 75]) {
        final good = vo2maxBands(age).good;
        if (prevGood != null) expect(good, lessThanOrEqualTo(prevGood));
        prevGood = good;
      }
    });

    test('decade boundaries pick the right table', () {
      expect(vo2maxBands(29).good, 47); // 20s
      expect(vo2maxBands(30).good, 44); // 30s
      expect(vo2maxBands(70).good, 32); // 70s
    });

    test('a fixed VO₂max grades better for an older user', () {
      // 40 ml/kg/min: "good" for a 25yo? no (good=47); "excellent" for a 65yo.
      expect(40 >= vo2maxBands(25).good, isFalse);
      expect(40 >= vo2maxBands(65).excellent, isTrue);
    });

    test('women\'s bands sit below men\'s at the same age', () {
      for (final age in [25, 45, 65]) {
        final m = vo2maxBands(age);
        final f = vo2maxBands(age, female: true);
        expect(f.excellent, lessThan(m.excellent));
        expect(f.good, lessThan(m.good));
        expect(f.fair, lessThan(m.fair));
      }
    });

    test('same VO₂max can grade differently by sex', () {
      // 41 ml/kg/min at 35: below "good" for a man (good=44) but at/above "good"
      // for a woman (good=38).
      expect(41 >= vo2maxBands(35).good, isFalse);
      expect(41 >= vo2maxBands(35, female: true).good, isTrue);
    });
  });

  group('hrvSdnnBands', () {
    test('good > moderate within each band', () {
      for (final age in [22, 35, 45, 55, 65, 75]) {
        final b = hrvSdnnBands(age);
        expect(b.good, greaterThan(b.moderate));
      }
    });

    test('cutoffs decline (or hold) with age', () {
      int? prev;
      for (final age in [25, 35, 45, 55, 65, 75]) {
        final good = hrvSdnnBands(age).good;
        if (prev != null) expect(good, lessThanOrEqualTo(prev));
        prev = good;
      }
    });
  });
}
