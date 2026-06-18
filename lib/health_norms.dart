import 'dart:math' as math;

// Age-banded reference cutoffs for the pre-workout readiness metrics.
//
// Glass Box: these are traceable to published norms, not invented. They replace
// the previous single fixed thresholds (which graded everyone against ~one age),
// so the color a metric shows now reflects what's normal *for the user's age*.
//
// Sex: VO₂max norms are strongly sex-specific, so the table picks men's or
// women's bands from the [female] flag (read from HealthKit biological sex, or a
// manual override). When sex is unknown the caller passes female:false → men's
// norms, matching the app's prior male-reference behavior. SDNN sex differences
// are small and inconsistent in the literature, so HRV grading stays age-only.
//
// Sources:
//  - VO₂max: ACSM / Cooper Institute (Aerobics Center Longitudinal Study) decade
//    norms by sex. "excellent" ≈ 80th percentile, "good" ≈ 60th, "fair" ≈ 40th;
//    aerobic capacity declines ~3 ml/kg/min per decade, and women's bands run
//    ~6–8 ml/kg/min below men's.
//  - SDNN: short-term (wearable / 5-min) resting HRV declines with age — healthy
//    adults ~35–65 ms, young adults up to ~80, >60 ~25–40 (MESA reference ranges
//    + wearable normative data).

/// VO₂max (ml/kg/min) band cutoffs for [age] and sex: `v >= excellent` → top
/// band, `>= good` → next, `>= fair` → next, else lowest. [female] selects the
/// women's table (men's otherwise). Age is clamped to the 20s–70s decade tables.
({int excellent, int good, int fair}) vo2maxBands(int age, {bool female = false}) {
  if (female) {
    if (age < 30) return (excellent: 45, good: 40, fair: 33);
    if (age < 40) return (excellent: 43, good: 38, fair: 31);
    if (age < 50) return (excellent: 40, good: 35, fair: 28);
    if (age < 60) return (excellent: 37, good: 32, fair: 25);
    if (age < 70) return (excellent: 34, good: 30, fair: 22);
    return (excellent: 31, good: 27, fair: 20);
  }
  if (age < 30) return (excellent: 52, good: 47, fair: 38);
  if (age < 40) return (excellent: 49, good: 44, fair: 35);
  if (age < 50) return (excellent: 46, good: 41, fair: 32);
  if (age < 60) return (excellent: 43, good: 38, fair: 29);
  if (age < 70) return (excellent: 40, good: 35, fair: 26);
  return (excellent: 37, good: 32, fair: 23);
}

/// Consumer-wearable resting-HR reference band (where ~95% of users fall),
/// sex-stratified. Quer et al., PLOS ONE 2020 (n=92,457 Fitbit adults, ~33M
/// daily readings): women 53–82 bpm, men 50–80 bpm. Wearable-derived, so it's
/// apples-to-apples with the app's Apple Watch / AirPods source — clinical
/// seated-pulse norms (NHANES ~71–76) run 5–11 bpm higher and would make a
/// watch reading look misleadingly low. Sex matters more than age here (women
/// average ~3 bpm higher; resting HR drifts down only modestly across adult
/// decades — Apple Heart & Movement Study 2026), so this band is sex-only with
/// the age drift noted in copy. [female] selects the women's band (men's
/// otherwise; unknown → men's, matching the app's other norms).
({int lo, int hi}) restingHrRefBand({bool female = false}) =>
    female ? (lo: 53, hi: 82) : (lo: 50, hi: 80);

/// Resting SDNN (ms) band cutoffs for [age]: `ms >= good` → good, `>= moderate`
/// → moderate, else low. (Age-only — see header note on SDNN and sex.)
({int good, int moderate}) hrvSdnnBands(int age) {
  if (age < 30) return (good: 60, moderate: 40);
  if (age < 40) return (good: 50, moderate: 35);
  if (age < 50) return (good: 45, moderate: 30);
  if (age < 60) return (good: 40, moderate: 28);
  if (age < 70) return (good: 35, moderate: 25);
  return (good: 30, moderate: 22);
}

// ── Population distributions ──────────────────────────────────────────────────
//
// Where the bands above give a few cutoffs, a [PopDist] gives the whole smooth
// population curve for a metric, so the app can place the user's reading as an
// approximate *percentile* ("about the 60th percentile for your age and sex")
// and draw the population it sits in. Everything here runs on-device: the user's
// value is compared against a curve already bundled in the binary, so no reading
// and no query ever leaves the phone. That is the entire privacy story for the
// general-population comparison — the risk a population overlay would otherwise
// carry lives in *querying* a server for the reference distribution, and there
// is no query.
//
// Glass Box: no new numbers are invented here. Each curve is a parametric model
// fitted to the SAME published percentile anchors the band cutoffs above already
// encode (Quer 2020 for resting HR; ACSM decade norms for VO₂max; MESA /
// wearable SDNN norms for HRV). The chosen shape is disclosed and deliberately
// simple — resting HR and VO₂max as Normal, SDNN as log-normal because resting
// HRV is right-skewed (and published SDNN reference equations are stated in
// log space). It is population context and an approximate percentile, never a
// precise clinical lookup — matching the "loose population context" framing the
// explainer already shows.
//
// Deliberately NOT here: any condition (e.g. Parkinson's) stratum. No openly
// licensed dataset supplies a PD-stratified HRV/RHR/VO₂max distribution, so a
// condition overlay can't be shipped as a bundled table — it would require
// opt-in cross-user aggregation under local differential privacy, a separate
// (and much harder) feature. These curves are age/sex only, on purpose.

/// A parametric population distribution used to place a user's value as a
/// percentile on a smooth curve, entirely on-device. [mu]/[sigma] live in the
/// model's native space: the raw value for a Normal, or the natural log of the
/// value for a [logNormal] (right-skewed) distribution.
class PopDist {
  const PopDist(
      {required this.mu,
      required this.sigma,
      required this.unit,
      this.logNormal = false});
  final double mu, sigma;
  final String unit;
  final bool logNormal;

  double _z(double value) {
    final x = logNormal ? math.log(value) : value;
    return (x - mu) / sigma;
  }

  /// Percentile (0–100) of [value] within this population.
  double percentileOf(double value) {
    if (logNormal && value <= 0) return 0;
    return (_normalCdf(_z(value)) * 100).clamp(0.0, 100.0);
  }

  /// The value at percentile [p] (p in 0–1) — the inverse of [percentileOf].
  double valueAt(double p) {
    final z = _probit(p.clamp(1e-4, 1 - 1e-4));
    final x = mu + z * sigma;
    return logNormal ? math.exp(x) : x;
  }

  /// Relative density at [value] (un-normalised; only ratios matter, for
  /// drawing the curve). The log-normal carries the extra 1/value Jacobian.
  double density(double value) {
    if (logNormal && value <= 0) return 0;
    final z = _z(value);
    final base = math.exp(-0.5 * z * z);
    return logNormal ? base / value : base;
  }
}

/// Fits a (log-)normal from two percentile anchors `p→v` (p in 0–1).
PopDist _fitDist(double p1, double v1, double p2, double v2, String unit,
    {bool logNormal = false}) {
  final z1 = _probit(p1), z2 = _probit(p2);
  final a1 = logNormal ? math.log(v1) : v1;
  final a2 = logNormal ? math.log(v2) : v2;
  final sigma = (a2 - a1) / (z2 - z1);
  final mu = a1 - z1 * sigma;
  return PopDist(mu: mu, sigma: sigma, unit: unit, logNormal: logNormal);
}

/// The population distribution for [key] (the metric-explainer keys: `bedHrv` /
/// `restingHrv`, `bedHr` / `restingHr`, `vo2max`), or null when an age-banded
/// metric has no [age]. Anchors (all from the already-cited bands above):
///  • resting HR — Quer 2020's band is the central 95% → 2.5th / 97.5th pct.
///  • VO₂max — ACSM decade norms: "fair" ≈ 40th, "excellent" ≈ 80th pct.
///  • SDNN (HRV) — the typical "moderate…good" band read as the interquartile
///    range (25th / 75th); log-normal to honour the right skew.
PopDist? popDistFor(String key, {int? age, bool? female}) {
  final f = female ?? false;
  switch (key) {
    case 'bedHr':
    case 'restingHr':
      final b = restingHrRefBand(female: f);
      return _fitDist(0.025, b.lo.toDouble(), 0.975, b.hi.toDouble(), 'bpm');
    case 'vo2max':
      if (age == null) return null;
      final b = vo2maxBands(age, female: f);
      return _fitDist(
          0.40, b.fair.toDouble(), 0.80, b.excellent.toDouble(), 'ml/kg/min');
    case 'bedHrv':
    case 'restingHrv':
      if (age == null) return null;
      final b = hrvSdnnBands(age);
      return _fitDist(0.25, b.moderate.toDouble(), 0.75, b.good.toDouble(), 'ms',
          logNormal: true);
  }
  return null;
}

/// The user's approximate percentile for [key] given their [value], rounded to
/// the nearest 5 and clamped to 5–95 (we never tell someone they are exactly
/// 0th or 100th, and the rounding avoids false precision). Null when there's no
/// distribution for the inputs or no positive value.
int? populationPercentile(String key, double value, {int? age, bool? female}) {
  if (value <= 0) return null;
  final d = popDistFor(key, age: age, female: female);
  if (d == null) return null;
  return ((d.percentileOf(value) / 5).round() * 5).clamp(5, 95);
}

// ── Personal distribution (your own history) ──────────────────────────────────
//
// Where [PopDist] is a modeled *population* curve, [PersonalDist] is the user's
// OWN readings — the empirical distribution of their measured values for a
// metric over their history. It needs no model and no anchors: the values ARE
// the distribution, so the percentile is exact (the fraction of your past
// readings at or below today's). This is the most private comparison there is —
// 100% the user's own data, read and computed on-device, nothing transmitted —
// and the most meaningful for tracking a personal trajectory. Plus surfaces it
// only in the paid Trends hub, where the longitudinal data lives.

/// The smallest number of historical readings that makes a personal
/// distribution worth drawing — below this it's noise, not a baseline (e.g.
/// a sparse VO₂max history of a couple of samples is correctly suppressed).
const int kMinPersonalReadings = 20;

/// The empirical distribution of a user's own readings for one metric.
class PersonalDist {
  PersonalDist(Iterable<double> values, {required this.unit})
      : _sorted = (List<double>.from(values)..sort());
  final List<double> _sorted;
  final String unit;

  int get count => _sorted.length;
  double get min => _sorted.first;
  double get max => _sorted.last;

  /// Empirical percentile (0–100) of [v]: values strictly below plus half of
  /// the ties (mid-rank), so a reading equal to the whole history reads ~50th.
  double percentileOf(double v) {
    if (_sorted.isEmpty) return 0;
    var below = 0, equal = 0;
    for (final x in _sorted) {
      if (x < v) {
        below++;
      } else if (x == v) {
        equal++;
      }
    }
    return ((below + equal / 2) / _sorted.length * 100).clamp(0.0, 100.0);
  }

  /// Counts of readings in [bins] equal-width buckets across [lo]..[hi]. Values
  /// outside the range clamp into the end bins (the caller sizes the range to
  /// cover the data, so this only catches the boundary).
  List<int> histogram(double lo, double hi, int bins) {
    final h = List<int>.filled(bins, 0);
    if (hi <= lo || bins <= 0) return h;
    for (final x in _sorted) {
      final i = (((x - lo) / (hi - lo)) * bins).floor().clamp(0, bins - 1);
      h[i]++;
    }
    return h;
  }
}

/// The user's personal percentile for [key] given [values] (their own history)
/// and the current [value] — rounded to the nearest 5 and clamped to 5–95, like
/// [populationPercentile]. Null when there aren't enough readings or no value.
int? personalPercentile(double value, Iterable<double> values) {
  final list = values.toList();
  if (value <= 0 || list.length < kMinPersonalReadings) return null;
  final p = PersonalDist(list, unit: '').percentileOf(value);
  return ((p / 5).round() * 5).clamp(5, 95);
}

/// Standard-normal CDF Φ(z) via the Abramowitz & Stegun 7.1.26 erf rational
/// approximation (|error| < 1.5e-7 — far finer than a percentile rounded to 5).
double _normalCdf(double z) => 0.5 * (1 + _erf(z / math.sqrt2));

double _erf(double x) {
  final s = x < 0 ? -1.0 : 1.0;
  final ax = x.abs();
  final t = 1 / (1 + 0.3275911 * ax);
  final y = 1 -
      (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t -
                  0.284496736) *
              t +
          0.254829592) *
          t *
          math.exp(-ax * ax);
  return s * y;
}

/// Inverse standard-normal CDF (probit) — Acklam's rational approximation,
/// |error| < 1.15e-9. Used both to fit curves from percentile anchors and to
/// read a value back at a given percentile.
double _probit(double p) {
  const a = [
    -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
    1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00
  ];
  const b = [
    -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
    6.680131188771972e+01, -1.328068155288572e+01
  ];
  const c = [
    -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
    -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00
  ];
  const d = [
    7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
    3.754408661907416e+00
  ];
  const pLow = 0.02425;
  const pHigh = 1 - pLow;
  if (p < pLow) {
    final q = math.sqrt(-2 * math.log(p));
    return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
        ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
  } else if (p <= pHigh) {
    final q = p - 0.5;
    final r = q * q;
    return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) *
        q /
        (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
  } else {
    final q = math.sqrt(-2 * math.log(1 - p));
    return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
        ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
  }
}
