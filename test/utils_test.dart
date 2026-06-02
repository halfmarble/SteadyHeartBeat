import 'package:flutter_test/flutter_test.dart';
import 'package:steady_heart_beat/utils.dart';

void main() {
  group('fmtDist — imperial', () {
    test('sub-0.1-mile shows feet', () {
      // 100 m ≈ 328 ft, well under 0.1 mi
      expect(fmtDist(100, true), '328 ft');
    });

    test('just under 0.1 mi (150 m) shows feet', () {
      // 150 m ≈ 0.0932 mi — still in feet range
      expect(fmtDist(150, true), '492 ft');
    });

    test('just over 0.1 mi (200 m) switches to miles', () {
      // 200 m ≈ 0.1243 mi
      expect(fmtDist(200, true), '0.12 mi');
    });

    test('1 mile formats to 2 decimal places', () {
      expect(fmtDist(1609.344, true), '1.00 mi');
    });

    test('half marathon (21.097 km) formats correctly', () {
      expect(fmtDist(21097, true), '13.11 mi');
    });

    test('0 m shows 0 ft', () {
      expect(fmtDist(0, true), '0 ft');
    });
  });

  group('fmtDist — metric', () {
    test('under 1000 m shows metres', () {
      expect(fmtDist(500, false), '500 m');
    });

    test('exactly 1000 m shows km', () {
      expect(fmtDist(1000, false), '1.00 km');
    });

    test('5 km formats to 2 decimal places', () {
      expect(fmtDist(5000, false), '5.00 km');
    });

    test('fractional metres rounds', () {
      expect(fmtDist(999.6, false), '1000 m');
    });

    test('0 m shows 0 m', () {
      expect(fmtDist(0, false), '0 m');
    });
  });

  group('fmtSteps', () {
    test('under 1000 shows raw integer', () {
      expect(fmtSteps(999), '999');
    });

    test('exactly 1000 shows 1.0k', () {
      expect(fmtSteps(1000), '1.0k');
    });

    test('1500 shows 1.5k', () {
      expect(fmtSteps(1500), '1.5k');
    });

    test('10000 shows 10.0k', () {
      expect(fmtSteps(10000), '10.0k');
    });

    test('0 shows 0', () {
      expect(fmtSteps(0), '0');
    });
  });
}
