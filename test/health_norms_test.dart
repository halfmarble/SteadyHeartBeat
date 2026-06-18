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

  group('restingHrRefBand', () {
    test('low < high for both sexes', () {
      for (final f in [false, true]) {
        final b = restingHrRefBand(female: f);
        expect(b.lo, lessThan(b.hi));
      }
    });

    test('matches the cited Quer et al. 2020 wearable 95% bands', () {
      expect(restingHrRefBand(), (lo: 50, hi: 80)); // men
      expect(restingHrRefBand(female: true), (lo: 53, hi: 82)); // women
    });

    test("women's band sits above men's (women average a few bpm higher)", () {
      final m = restingHrRefBand();
      final f = restingHrRefBand(female: true);
      expect(f.lo, greaterThan(m.lo));
      expect(f.hi, greaterThan(m.hi));
    });

    test('unknown sex defaults to the men\'s band', () {
      expect(restingHrRefBand(), restingHrRefBand(female: false));
    });
  });

  group('popDistFor / population curve', () {
    test('age-banded metrics need an age; resting HR does not', () {
      expect(popDistFor('vo2max'), isNull);
      expect(popDistFor('bedHrv'), isNull);
      expect(popDistFor('restingHrv'), isNull);
      expect(popDistFor('restingHr'), isNotNull); // sex-only
      expect(popDistFor('vo2max', age: 45), isNotNull);
      expect(popDistFor('bedHrv', age: 45), isNotNull);
    });

    test('unknown key has no distribution', () {
      expect(popDistFor('steps', age: 45), isNull);
    });

    test('the fitted curve reproduces its published percentile anchors', () {
      // resting HR — Quer band edges are the 2.5th / 97.5th percentiles.
      final hr = popDistFor('restingHr', female: false)!; // 50–80 bpm
      expect(hr.percentileOf(50), closeTo(2.5, 0.3));
      expect(hr.percentileOf(80), closeTo(97.5, 0.3));
      expect(hr.percentileOf(65), closeTo(50, 0.5)); // band midpoint

      // VO₂max — ACSM "fair" ≈ 40th, "excellent" ≈ 80th.
      final v = popDistFor('vo2max', age: 45, female: false)!;
      final vb = vo2maxBands(45);
      expect(v.percentileOf(vb.fair.toDouble()), closeTo(40, 0.5));
      expect(v.percentileOf(vb.excellent.toDouble()), closeTo(80, 0.5));

      // SDNN (HRV) — typical moderate…good band read as the 25th / 75th (IQR).
      final h = popDistFor('bedHrv', age: 45)!;
      final hb = hrvSdnnBands(45);
      expect(h.percentileOf(hb.moderate.toDouble()), closeTo(25, 0.5));
      expect(h.percentileOf(hb.good.toDouble()), closeTo(75, 0.5));
    });

    test('SDNN curve is log-normal (right-skewed), the others normal', () {
      expect(popDistFor('bedHrv', age: 45)!.logNormal, isTrue);
      expect(popDistFor('restingHrv', age: 45)!.logNormal, isTrue);
      expect(popDistFor('restingHr')!.logNormal, isFalse);
      expect(popDistFor('vo2max', age: 45)!.logNormal, isFalse);
    });

    test('valueAt inverts percentileOf', () {
      final v = popDistFor('vo2max', age: 50, female: true)!;
      for (final p in [0.1, 0.5, 0.9]) {
        expect(v.percentileOf(v.valueAt(p)) / 100, closeTo(p, 1e-3));
      }
    });

    test('percentile rises monotonically with the reading', () {
      final v = popDistFor('vo2max', age: 40, female: false)!;
      expect(v.percentileOf(35), lessThan(v.percentileOf(45)));
      expect(v.percentileOf(45), lessThan(v.percentileOf(55)));
    });

    test('populationPercentile rounds to 5 and clamps to 5–95', () {
      // Band midpoint → ~50th.
      expect(populationPercentile('restingHr', 65, female: false), 50);
      // Extremes never read as 0th/100th.
      expect(populationPercentile('restingHr', 20, female: false), 5);
      expect(populationPercentile('restingHr', 120, female: false), 95);
      // Every output is a multiple of 5 in [5, 95].
      for (final val in [40, 50, 60, 70, 90]) {
        final p = populationPercentile('restingHr', val.toDouble())!;
        expect(p % 5, 0);
        expect(p, inInclusiveRange(5, 95));
      }
    });

    test('populationPercentile is null without a usable value or distribution',
        () {
      expect(populationPercentile('restingHr', 0), isNull); // non-positive
      expect(populationPercentile('vo2max', 45), isNull); // no age
      expect(populationPercentile('steps', 5000, age: 40), isNull); // no curve
    });

    test('density is positive in-range and the curve has a single peak', () {
      final v = popDistFor('vo2max', age: 40, female: false)!;
      final peak = v.valueAt(0.5);
      expect(v.density(peak), greaterThan(v.density(peak - 10)));
      expect(v.density(peak), greaterThan(v.density(peak + 10)));
      // Log-normal density is 0 at/below zero (guards the draw window).
      expect(popDistFor('bedHrv', age: 40)!.density(0), 0);
    });
  });

  group('PersonalDist / personal history', () {
    // A simple, known sample: 1..100.
    final h = [for (var i = 1; i <= 100; i++) i.toDouble()];

    test('count / min / max reflect the readings', () {
      final d = PersonalDist(h, unit: 'bpm');
      expect(d.count, 100);
      expect(d.min, 1);
      expect(d.max, 100);
    });

    test('empirical percentile: median ~50, extremes near the ends', () {
      final d = PersonalDist(h, unit: 'bpm');
      expect(d.percentileOf(50), closeTo(50, 1));
      expect(d.percentileOf(1), lessThan(2)); // mid-rank of the lowest
      expect(d.percentileOf(100), greaterThan(98));
      expect(d.percentileOf(25), closeTo(25, 1));
    });

    test('percentile rises monotonically with the reading', () {
      final d = PersonalDist(h, unit: 'bpm');
      expect(d.percentileOf(20), lessThan(d.percentileOf(40)));
      expect(d.percentileOf(40), lessThan(d.percentileOf(80)));
    });

    test('a reading equal to the whole history reads ~50th (mid-rank ties)', () {
      final flat = List<double>.filled(40, 60);
      expect(PersonalDist(flat, unit: 'bpm').percentileOf(60), closeTo(50, 0.01));
    });

    test('histogram bins sum to the reading count and cover the range', () {
      final d = PersonalDist(h, unit: 'bpm');
      final bins = d.histogram(0, 100, 10);
      expect(bins.length, 10);
      expect(bins.fold<int>(0, (a, b) => a + b), 100);
      expect(bins.every((c) => c > 0), isTrue); // uniform data → no empty bin
    });

    test('personalPercentile gates on a value + enough readings, rounds to 5', () {
      // Below the minimum-readings floor → null.
      final few = [for (var i = 0; i < kMinPersonalReadings - 1; i++) 60.0];
      expect(personalPercentile(60, few), isNull);
      // Non-positive value → null.
      expect(personalPercentile(0, h), isNull);
      // Enough readings → a multiple of 5 in [5, 95].
      final p = personalPercentile(50, h)!;
      expect(p % 5, 0);
      expect(p, inInclusiveRange(5, 95));
      expect(p, 50);
    });
  });
}
