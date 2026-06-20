import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants.dart';
import '../health_norms.dart';

/// A peer-reviewed source for a metric's health information, shown under
/// "Sources" in the explainer sheet (App Store Guideline 1.4.1). [url] is
/// optional — a textbook citation has no link; everything else points to
/// PubMed / PMC / a DOI.
class Citation {
  final String label;
  final String? url;
  const Citation(this.label, [this.url]);
}

/// Plain-language explainers for the readiness-snapshot metrics, surfaced by the
/// ⓘ affordance on each chip (home screen). Glass Box: the meaning of every
/// number is one tap away — especially important for "bed HRV" / "bed HR", whose
/// values intentionally won't match other apps (different HRV measure + window).
///
/// Keep the copy free of FDA-restricted language ("treat", "diagnose",
/// "prevent", etc.) — these are general-wellness readings under the FDA 2019
/// General Wellness Policy. Health figures carry [sources] so the medical
/// information is cited in-app.
class MetricExplainer {
  final String title;
  final List<String> paragraphs;
  final List<Citation> sources;
  const MetricExplainer(this.title, this.paragraphs,
      {this.sources = const []});
}

// Shared citations, reused across the workout-stat explainers and the standalone
// "How it works" science screen so both surfaces cite the same sources.
const Citation kCiteTanaka = Citation(
    'Age-predicted maximum heart rate — Tanaka, Monahan & Seals, J Am Coll '
    'Cardiol 2001',
    'https://doi.org/10.1016/S0735-1097(00)01054-8');
const Citation kCiteAcsmIntensity = Citation(
    'Exercise intensity by %max HR — ACSM Position Stand (Garber et al.), Med '
    'Sci Sports Exerc 2011',
    'https://pubmed.ncbi.nlm.nih.gov/21694556/');
const Citation kCiteZonesThreshold = Citation(
    '%max-HR zones vs. threshold anchoring — Wolpern et al., BMC Sports Sci Med '
    'Rehabil 2015',
    'https://pubmed.ncbi.nlm.nih.gov/26146564/');

const Map<String, MetricExplainer> kMetricExplainers = {
  'bedHrv': MetricExplainer('bed HRV', [
    'Bed HRV is the typical (median) heart-rate variability across your night — '
        'from when you fall asleep until your final wake-up, with brief mid-night '
        'wake-ups included (the time you lie in bed awake at the end isn’t).',
    'Taking the median across the full in-bed window is deliberately robust to '
        'the watch mislabelling movement as “awake” (common with restless or '
        'dream-enacting sleep), so real sleep isn’t dropped — at the cost of a '
        'coarser number than one restricted to deep sleep. Read it as a '
        'night-to-night trend, not a precise value.',
    'Watch your own baseline over time — the trend matters more than any single '
        'night, and there is no universal “good” value. A higher reading often '
        'tracks with feeling more recovered, but HRV isn’t one-directional — it '
        'can also rise with hard strain or illness — so weigh it over several '
        'nights and against how you feel, never as a single-night verdict.',
    'If you track HRV in another app, expect a different number: many use a '
        'different measure (rMSSD) over only the deepest part of sleep, while bed '
        'HRV uses SDNN across your full night.',
    'Heart-rate variability from a consumer watch is a rough guide, not a lab '
        'measurement. It is less reliable than heart rate, and the SDNN figure '
        'has not been independently validated against clinical equipment or in '
        'any particular health condition — so follow your own trend over time '
        'rather than reading much into any single value.',
    'This is a general wellness reading, not a medical measurement.',
  ], sources: [
    Citation('HRV reference ranges — MESA (Multi-Ethnic Study of Atherosclerosis)',
        'https://pmc.ncbi.nlm.nih.gov/articles/PMC5010946/'),
    Citation(
        'Consumer-watch SDNN validity — Hsu et al., Eur Heart J Digit Health 2023',
        'https://pubmed.ncbi.nlm.nih.gov/37265873/'),
  ]),
  'restingHrv': MetricExplainer('resting HRV', [
    'This is your current heart-rate variability (SDNN) — your most recent '
        'reading from Apple Health, or a value you entered yourself.',
    'Once your watch records variability across a night in bed, this becomes '
        '“bed HRV”: the median across your whole night, a steadier '
        'number to track.',
    'Heart-rate variability from a consumer watch is a rough guide, not a lab '
        'measurement. It is less reliable than heart rate, and the SDNN figure '
        'has not been independently validated against clinical equipment or in '
        'any particular health condition — watch your own trend, not the exact '
        'number.',
    'This is a general wellness reading, not a medical measurement.',
  ], sources: [
    Citation('HRV reference ranges — MESA (Multi-Ethnic Study of Atherosclerosis)',
        'https://pmc.ncbi.nlm.nih.gov/articles/PMC5010946/'),
    Citation(
        'Consumer-watch SDNN validity — Hsu et al., Eur Heart J Digit Health 2023',
        'https://pubmed.ncbi.nlm.nih.gov/37265873/'),
  ]),
  'bedHr': MetricExplainer('bed HR', [
    'Bed HR is your average heart rate across the same window — your night, '
        'from falling asleep to your final wake-up (the time you lie in bed awake '
        'at the end isn’t counted).',
    'It is close to a resting heart rate but taken over the full night, so brief '
        'stirrings nudge it up a little. Lower, steadier nights generally track '
        'with better recovery.',
    'It differs from Apple’s “Resting Heart Rate,” which is '
        'computed a different way, so the two won’t always match. Watch your '
        'own baseline rather than comparing to anyone else.',
    'This is a general wellness reading, not a medical measurement.',
  ], sources: [
    Citation('Resting-HR reference ranges — Quer et al., PLOS ONE 2020 '
        '(n=92,457 wearable users)',
        'https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0227709'),
    Citation('Overnight / resting HR & recovery — Dial et al., Physiol Rep 2025',
        'https://pmc.ncbi.nlm.nih.gov/articles/PMC12367097/'),
    Citation('Apple Watch resting-HR accuracy (peer-reviewed validation)',
        'https://pmc.ncbi.nlm.nih.gov/articles/PMC11478500/'),
  ]),
  'restingHr': MetricExplainer('resting HR', [
    'This is your current resting heart rate — your most recent reading from '
        'Apple Health, or a value you entered yourself.',
    'Once your watch records heart rate across a night in bed, this becomes '
        '“bed HR”: your average across the whole night.',
    'This is a general wellness reading, not a medical measurement.',
  ], sources: [
    Citation('Resting-HR reference ranges — Quer et al., PLOS ONE 2020 '
        '(n=92,457 wearable users)',
        'https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0227709'),
    Citation('Overnight / resting HR & recovery — Dial et al., Physiol Rep 2025',
        'https://pmc.ncbi.nlm.nih.gov/articles/PMC12367097/'),
    Citation('Apple Watch resting-HR accuracy (peer-reviewed validation)',
        'https://pmc.ncbi.nlm.nih.gov/articles/PMC11478500/'),
  ]),
  'vo2max': MetricExplainer('VO₂ max', [
    'VO₂ max estimates how efficiently your body uses oxygen during '
        'exercise — a broad marker of cardio fitness. We read it straight from '
        'Apple Health.',
    'Apple only updates it from outdoor walks, runs, or hikes with GPS and heart '
        'rate lasting around 20 minutes. Just wearing your watch won’t '
        'refresh it, so the date can read months old until your next qualifying '
        'outdoor workout.',
    'A higher value generally reflects better aerobic fitness for your age and '
        'sex.',
    'Apple’s figure is an estimate from your everyday workouts, not a lab test — '
        'it can be off by several points and is least reliable at the very high '
        'and very low ends of fitness, so follow the trend, not the exact number.',
    'This is a general wellness estimate, not a medical measurement.',
  ], sources: [
    Citation('VO₂ max fitness norms — ACSM’s Guidelines for Exercise Testing & '
        'Prescription, 11th ed. (2021)'),
    Citation('Apple Watch VO₂ max validity — PLOS ONE 2025',
        'https://pubmed.ncbi.nlm.nih.gov/40373042/'),
  ]),
  // ── Workout-stat explainers (the ⓘ on the post-workout / saved-session chips).
  'maxHr': MetricExplainer('max HR', [
    'This is the highest heart rate your AirPods recorded during this workout — '
        'your single peak reading, straight from the sensor, with no formula '
        'applied.',
    'Don’t confuse it with your estimated maximum heart rate, which we work out '
        'from your age (208 − 0.7 × age) and use to set your zones, your effort '
        'percentage, and the danger threshold. Your measured peak can land above '
        'or below that estimate — the estimate is a population average, and real '
        'maximums vary a lot from person to person.',
    'This is a general wellness reading, not a medical measurement.',
  ], sources: [kCiteTanaka]),
  'avgHr': MetricExplainer('avg HR', [
    'Your average heart rate across the whole workout, weighted by time — longer '
        'stretches count for more than brief spikes, so it reflects how hard the '
        'session was overall rather than any single moment.',
    'This is a general wellness reading, not a medical measurement.',
  ]),
  'effort': MetricExplainer('effort', [
    'Effort is your average heart rate as a percentage of your estimated maximum '
        '(average HR ÷ estimated max HR × 100). As a rough guide, 60–70% is easy '
        'aerobic work, 70–80% is tempo, 80–90% is hard, and 90%+ is near your '
        'ceiling.',
    'Because it’s built on an age-estimated maximum (208 − 0.7 × age), read it '
        'as a rough guide, not a precise figure. Percent-of-max is a coarse way '
        'to gauge intensity — anchoring to your own measured thresholds is more '
        'accurate — and some conditions, including the effect of certain '
        'Parkinson’s medications on heart rate, can blunt the response and make '
        'the number read low for the real effort.',
    'This is a general wellness reading, not a medical measurement.',
  ], sources: [kCiteTanaka, kCiteAcsmIntensity, kCiteZonesThreshold]),
  'kcal': MetricExplainer('kcal', [
    'This calorie figure comes straight from Apple Health’s own active-energy '
        'estimate for the workout, which iOS calculates from your heart rate, '
        'movement, and body metrics. We show it as-is — it isn’t computed by '
        'this app.',
    'Apple’s method is its own, and like every wearable calorie estimate it’s an '
        'approximation, so follow the trend rather than reading any single '
        'number as exact.',
    'This is a general wellness estimate, not a medical measurement.',
  ]),
};

/// Presents the explainer for [key] as a bottom sheet. No-op for an unknown key.
/// [age] / [female] (from the user's health profile) let it show a sex/age-
/// matched "expected range" from the cited norms; omit them and the range box is
/// simply skipped.
Future<void> showMetricExplainer(BuildContext context, String key,
    {int? age, bool? female, double? value, List<double>? personalValues}) async {
  final info = kMetricExplainers[key];
  if (info == null) return;
  final gauge = gaugeSpec(key, age: age, female: female, value: value);
  // When we can draw the gauge (we have a value) and a population curve exists
  // for the metric, the gauge becomes a full distribution with the user's
  // percentile — computed on-device against a bundled curve, no query.
  final dist =
      gauge == null ? null : popDistFor(key, age: age, female: female);
  final pct = dist == null
      ? null
      : populationPercentile(key, value!, age: age, female: female);
  // "Vs your own history": the empirical distribution of the user's past
  // readings. Only the paid Trends hub passes [personalValues]; the free home
  // explainer leaves it null, so this section is structurally Plus-only. Needs
  // a current value and enough history to be a baseline (see kMinPersonalReadings).
  final personal = (personalValues != null &&
          value != null &&
          value > 0 &&
          personalValues.length >= kMinPersonalReadings)
      ? PersonalDist(personalValues, unit: _unitForKey(key))
      : null;
  final personalPct =
      personal == null ? null : personalPercentile(value!, personalValues!);
  // Fall back to a text range only when we can't draw the gauge (no value).
  final refRange =
      gauge == null ? referenceRange(key, age: age, female: female) : null;
  // Cap at 85% so a tap-to-dismiss scrim and the grabber stay reachable even
  // when the content is long; the body scrolls inside.
  final maxH = MediaQuery.of(context).size.height * 0.85;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: maxH),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: kTextDim,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              info.title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: kFontXL,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Expected-range box first, directly under the title.
                    if (refRange != null || gauge != null) ...[
                      _ReferenceRangeBox(
                          text: refRange,
                          gauge: gauge,
                          dist: dist,
                          percentile: pct),
                      const SizedBox(height: 16),
                    ],
                    // Then "vs your own history" (Plus Trends only).
                    if (personal != null) ...[
                      _PersonalHistoryBox(
                          dist: personal,
                          value: value!,
                          percentile: personalPct),
                      const SizedBox(height: 16),
                    ],
                    for (final p in info.paragraphs) ...[
                      Text(
                        p,
                        style: const TextStyle(
                            color: kTextSubtle, fontSize: kFontMD, height: 1.45),
                      ),
                      const SizedBox(height: 12),
                    ],
                    SourcesBlock(info.sources),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The "expected range for your age/sex" line for [key], or null when we lack
/// the inputs (no age for the age-banded metrics) or the metric has no sourced
/// range. Glass Box: every figure traces to the cited norms shown below it —
/// MESA (HRV SDNN), ACSM (VO₂max), Quer 2020 (resting HR). Framed as loose
/// population context, never a personal target.
@visibleForTesting
String? referenceRange(String key, {int? age, bool? female}) {
  final f = female ?? false;
  switch (key) {
    case 'bedHrv':
    case 'restingHrv':
      if (age == null) return null;
      final b = hrvSdnnBands(age);
      return 'For your age, a typical overnight SDNN runs roughly '
          '${b.moderate}–${b.good} ms. Individual variation is large, and a '
          'consumer watch reads differently from clinical equipment.';
    case 'bedHr':
    case 'restingHr':
      final b = restingHrRefBand(female: f);
      return 'For your sex, about 95% of wearable users sit near '
          '${b.lo}–${b.hi} bpm (women average a few bpm higher than men); resting '
          'heart rate also drifts down modestly with age.';
    case 'vo2max':
      if (age == null) return null;
      final b = vo2maxBands(age, female: f);
      return 'For your age and sex, about ${b.fair}–${b.excellent} ml/kg/min '
          'spans “fair” to “excellent”.';
  }
  return null;
}

/// Inputs for the visual range gauge: where the user's [value] sits relative to
/// the normal [lo]–[hi] band, on an [axisMin]–[axisMax] scale.
class GaugeSpec {
  const GaugeSpec(
      {required this.value,
      required this.lo,
      required this.hi,
      required this.axisMin,
      required this.axisMax,
      required this.unit});
  final double value, lo, hi, axisMin, axisMax;
  final String unit;
}

/// Builds the gauge spec for [key] from the cited norms + the user's [value],
/// or null when we lack a value or an age-banded metric has no age. Bands:
/// HRV → MESA SDNN, resting HR → Quer 2020, VO₂max → ACSM.
@visibleForTesting
GaugeSpec? gaugeSpec(String key, {int? age, bool? female, double? value}) {
  if (value == null || value <= 0) return null;
  final f = female ?? false;
  switch (key) {
    case 'bedHrv':
    case 'restingHrv':
      if (age == null) return null;
      final b = hrvSdnnBands(age);
      return GaugeSpec(
          value: value,
          lo: b.moderate.toDouble(),
          hi: b.good.toDouble(),
          axisMin: 0,
          axisMax: (b.good + 40).toDouble(),
          unit: 'ms');
    case 'bedHr':
    case 'restingHr':
      final b = restingHrRefBand(female: f);
      return GaugeSpec(
          value: value,
          lo: b.lo.toDouble(),
          hi: b.hi.toDouble(),
          axisMin: 40,
          axisMax: 110,
          unit: 'bpm');
    case 'vo2max':
      if (age == null) return null;
      final b = vo2maxBands(age, female: f);
      return GaugeSpec(
          value: value,
          lo: b.fair.toDouble(),
          hi: b.excellent.toDouble(),
          axisMin: (b.fair - 12).clamp(0, 100).toDouble(),
          axisMax: (b.excellent + 10).toDouble(),
          unit: 'ml/kg/min');
  }
  return null;
}

String _fmt(double v) => v.round().toString();

/// Display unit for a metric key — used by the personal-history box, which can
/// render even when there's no age (and thus no [GaugeSpec] to read a unit off).
String _unitForKey(String key) => switch (key) {
      'bedHrv' || 'restingHrv' => 'ms',
      'bedHr' || 'restingHr' => 'bpm',
      'vo2max' => 'ml/kg/min',
      _ => '',
    };

/// The sex/age-matched "expected range" card, shown above SOURCES. Prefers a
/// visual [gauge] (your value marked against the normal band); falls back to a
/// [text] line when no value is available. The fixed caveat keeps it honest per
/// the Glass Box / FDA General Wellness framing.
class _ReferenceRangeBox extends StatelessWidget {
  const _ReferenceRangeBox({this.text, this.gauge, this.dist, this.percentile});
  final String? text;
  final GaugeSpec? gauge;
  final PopDist? dist;
  final int? percentile;

  @override
  Widget build(BuildContext context) {
    final g = gauge;
    final d = dist;
    // Header reads "WHERE YOU LAND" once we can show the user on the population
    // curve; otherwise it stays the plain expected-range card.
    final showCurve = g != null && d != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: kSurfaceDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kTextDim.withAlpha(0x55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(showCurve ? 'WHERE YOU LAND' : 'EXPECTED RANGE',
              style: const TextStyle(
                  color: kTextMuted,
                  fontSize: kFontSM,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2)),
          const SizedBox(height: 14),
          if (showCurve) ...[
            _DistributionCurve(g, d),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    percentile == null
                        ? 'You  ${_fmt(g.value)} ${g.unit}'
                        : 'You  ${_fmt(g.value)} ${g.unit}  ·  around the '
                            '${percentile}th percentile for your age and sex',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: kFontMD,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ] else if (g != null) ...[
            _RangeGauge(g),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('You  ${_fmt(g.value)} ${g.unit}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: kFontMD,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                Container(
                  width: 12,
                  height: 8,
                  decoration: BoxDecoration(
                      color: kAccent.withAlpha(0x66),
                      borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 6),
                const Text('typical range',
                    style: TextStyle(color: kTextSubtle, fontSize: kFontSM)),
              ],
            ),
            const SizedBox(height: 10),
          ] else if (text != null) ...[
            Text(text!,
                style: const TextStyle(
                    color: Colors.white, fontSize: kFontMD, height: 1.45)),
            const SizedBox(height: 8),
          ],
          const Text(
            'Loose population context, not a personal target or a diagnosis — '
            'your own trend over time matters more than how you compare to others.',
            style: TextStyle(color: kTextDim, fontSize: kFontSM, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// Horizontal gauge: a full track, the normal band highlighted with its min/max
/// labelled at the band edges, and the user's value as a white marker.
class _RangeGauge extends StatelessWidget {
  const _RangeGauge(this.spec);
  final GaugeSpec spec;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      double fx(double v) => ((v - spec.axisMin) / (spec.axisMax - spec.axisMin))
          .clamp(0.0, 1.0);
      final bandLx = fx(spec.lo) * w;
      final bandRx = fx(spec.hi) * w;
      final bandW = (bandRx - bandLx).clamp(2.0, w);
      final markX = fx(spec.value) * w;
      const lblW = 32.0;
      Widget edgeLabel(double x, String s) => Positioned(
            left: (x - lblW / 2).clamp(0.0, w - lblW),
            width: lblW,
            child: Text(s,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kTextMuted, fontSize: kFontSM)),
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 18,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                      color: kSurface, borderRadius: BorderRadius.circular(4)),
                ),
                Positioned(
                  left: bandLx,
                  child: Container(
                    width: bandW,
                    height: 8,
                    decoration: BoxDecoration(
                        color: kAccent.withAlpha(0x66),
                        borderRadius: BorderRadius.circular(4)),
                  ),
                ),
                Positioned(
                  left: (markX - 2).clamp(0.0, w - 4),
                  child: Container(
                    width: 4,
                    height: 18,
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(color: kSurfaceDark, width: 1)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          // Typical min / max printed under the band's edges.
          SizedBox(
            height: 14,
            child: Stack(children: [
              edgeLabel(bandLx, _fmt(spec.lo)),
              edgeLabel(bandRx, _fmt(spec.hi)),
            ]),
          ),
        ],
      );
    });
  }
}

/// The population-distribution view: a smooth curve of where everyone (the
/// user's age/sex band) falls, the typical range shaded under it, and the user
/// marked with a vertical line + dot where they meet the curve. Drawn from a
/// [PopDist] bundled in the binary — entirely on-device, the reading never
/// leaves the phone. Replaces the flat [_RangeGauge] whenever a curve exists.
class _DistributionCurve extends StatelessWidget {
  const _DistributionCurve(this.spec, this.dist);
  final GaugeSpec spec;
  final PopDist dist;

  @override
  Widget build(BuildContext context) {
    // Draw window: the bulk of the population (2nd–98th pct) widened to take in
    // the user's value and the typical band, then padded a touch on each side.
    final lo2 = dist.valueAt(0.02);
    final hi98 = dist.valueAt(0.98);
    var aMin = math.min(math.min(lo2, spec.lo), spec.value);
    var aMax = math.max(math.max(hi98, spec.hi), spec.value);
    final pad = (aMax - aMin) * 0.06;
    aMin -= pad;
    aMax += pad;
    if (dist.logNormal && aMin < 0) aMin = 0;

    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      double fx(double v) => ((v - aMin) / (aMax - aMin)).clamp(0.0, 1.0) * w;
      const lblW = 36.0;
      Widget edgeLabel(double x, String s) => Positioned(
            left: (x - lblW / 2).clamp(0.0, w - lblW),
            width: lblW,
            child: Text(s,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kTextMuted, fontSize: kFontSM)),
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: w,
            height: 64,
            child: CustomPaint(painter: _CurvePainter(spec, dist, aMin, aMax)),
          ),
          const SizedBox(height: 3),
          // Typical min / max printed under the band's edges (matches the gauge).
          SizedBox(
            height: 14,
            child: Stack(children: [
              edgeLabel(fx(spec.lo), _fmt(spec.lo)),
              edgeLabel(fx(spec.hi), _fmt(spec.hi)),
            ]),
          ),
        ],
      );
    });
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.spec, this.dist, this.aMin, this.aMax);
  final GaugeSpec spec;
  final PopDist dist;
  final double aMin, aMax;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const base = 2.0; // baseline padding from the bottom edge
    final usableH = h - base;
    const n = 96;
    double fx(double v) => ((v - aMin) / (aMax - aMin)).clamp(0.0, 1.0) * w;

    // Sample the density across the window; track the max for normalisation.
    final xs = <double>[];
    final ds = <double>[];
    double maxD = 0;
    for (var i = 0; i <= n; i++) {
      final v = aMin + (aMax - aMin) * i / n;
      final den = dist.density(v);
      xs.add(v);
      ds.add(den);
      if (den > maxD) maxD = den;
    }
    if (maxD <= 0) return;
    double fy(double den) => h - base - (den / maxD) * usableH * 0.92;

    // Curve stroke path + a closed fill path along the baseline.
    final curve = Path();
    final fill = Path()..moveTo(fx(xs.first), h - base);
    for (var i = 0; i <= n; i++) {
      final x = fx(xs[i]);
      final y = fy(ds[i]);
      i == 0 ? curve.moveTo(x, y) : curve.lineTo(x, y);
      fill.lineTo(x, y);
    }
    fill.lineTo(fx(xs.last), h - base);
    fill.close();

    // Faint fill under the whole curve.
    canvas.drawPath(
        fill,
        Paint()
          ..color = kTextDim.withAlpha(0x22)
          ..style = PaintingStyle.fill);

    // Typical-band region (lo..hi) shaded accent, clipped to the curve fill so
    // it tints only the area beneath the curve.
    canvas.save();
    canvas.clipPath(fill);
    canvas.drawRect(Rect.fromLTRB(fx(spec.lo), 0, fx(spec.hi), h),
        Paint()..color = kAccent.withAlpha(0x3A));
    canvas.restore();

    // Curve stroke.
    canvas.drawPath(
        curve,
        Paint()
          ..color = kTextMuted
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round);

    // User marker: a thin white vertical line at their value, with a dot where
    // it crosses the curve — "you are here" on the population.
    final mx = fx(spec.value);
    final topY = fy(dist.density(spec.value.clamp(aMin, aMax)));
    canvas.drawLine(
        Offset(mx, 0),
        Offset(mx, h - base),
        Paint()
          ..color = Colors.white.withAlpha(0xCC)
          ..strokeWidth = 2);
    canvas.drawCircle(
        Offset(mx, topY),
        3.5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) =>
      old.spec.value != spec.value ||
      old.spec.lo != spec.lo ||
      old.spec.hi != spec.hi ||
      old.aMin != aMin ||
      old.aMax != aMax ||
      !identical(old.dist, dist);
}

/// "VS YOUR OWN HISTORY": the empirical distribution of the user's own past
/// readings as a histogram, with today's value marked and its exact percentile
/// among them. Drawn from values read on-device (Plus Trends only) — the most
/// private comparison, and the one that tracks a personal trajectory rather than
/// a population. Distinct visual language from the population curve (real bars,
/// not a modeled curve) so the two read as different things.
class _PersonalHistoryBox extends StatelessWidget {
  const _PersonalHistoryBox(
      {required this.dist, required this.value, this.percentile});
  final PersonalDist dist;
  final double value;
  final int? percentile;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: kSurfaceDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kTextDim.withAlpha(0x55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('VS YOUR OWN HISTORY',
              style: TextStyle(
                  color: kTextMuted,
                  fontSize: kFontSM,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2)),
          const SizedBox(height: 14),
          _PersonalHistogram(dist, value),
          const SizedBox(height: 10),
          Text(
            percentile == null
                ? 'You  ${_fmt(value)} ${dist.unit}'
                : 'You  ${_fmt(value)} ${dist.unit}  ·  ${percentile}th percentile '
                    'of your own readings',
            style: const TextStyle(
                color: Colors.white,
                fontSize: kFontMD,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Your own ${dist.count} readings to date — the bars are your actual '
            'history, not a model. Your trend over time matters more than any '
            'single reading.',
            style: const TextStyle(
                color: kTextDim, fontSize: kFontSM, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _PersonalHistogram extends StatelessWidget {
  const _PersonalHistogram(this.dist, this.value);
  final PersonalDist dist;
  final double value;

  @override
  Widget build(BuildContext context) {
    // Range covers the user's readings, widened to include today's value, padded.
    var lo = math.min(dist.min, value);
    var hi = math.max(dist.max, value);
    if (hi <= lo) hi = lo + 1;
    final pad = (hi - lo) * 0.04;
    lo -= pad;
    hi += pad;

    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      double fx(double v) => ((v - lo) / (hi - lo)).clamp(0.0, 1.0) * w;
      const lblW = 40.0;
      Widget edge(double x, String s) => Positioned(
            left: (x - lblW / 2).clamp(0.0, w - lblW),
            width: lblW,
            child: Text(s,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kTextMuted, fontSize: kFontSM)),
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: w,
            height: 64,
            child: CustomPaint(painter: _HistogramPainter(dist, value, lo, hi)),
          ),
          const SizedBox(height: 3),
          // Your lowest / highest reading under the bars' span.
          SizedBox(
            height: 14,
            child: Stack(children: [
              edge(fx(dist.min), _fmt(dist.min)),
              edge(fx(dist.max), _fmt(dist.max)),
            ]),
          ),
        ],
      );
    });
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.dist, this.value, this.lo, this.hi);
  final PersonalDist dist;
  final double value, lo, hi;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const base = 2.0;
    const bins = 30;
    final counts = dist.histogram(lo, hi, bins);
    final maxC = counts.fold<int>(0, math.max);
    if (maxC <= 0) return;
    final binW = w / bins;

    final barPaint = Paint()..color = kAccent.withAlpha(0x66);
    for (var i = 0; i < bins; i++) {
      if (counts[i] == 0) continue;
      final bh = (counts[i] / maxC) * (h - base) * 0.92;
      final x = i * binW;
      canvas.drawRect(
          Rect.fromLTWH(x + 0.5, h - base - bh, binW - 1, bh), barPaint);
    }

    // Today's value: a white vertical marker across the plot.
    final mx = (((value - lo) / (hi - lo)).clamp(0.0, 1.0)) * w;
    canvas.drawLine(
        Offset(mx, 0),
        Offset(mx, h - base),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter old) =>
      old.value != value ||
      old.lo != lo ||
      old.hi != hi ||
      !identical(old.dist, dist);
}

/// The "SOURCES" header followed by one [CitationRow] per source — the cited
/// footer of a metric explainer. Pulled out so the standalone "How it works"
/// science screen cites in exactly the same style. Renders nothing when empty.
class SourcesBlock extends StatelessWidget {
  const SourcesBlock(this.sources, {super.key});
  final List<Citation> sources;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        const Text('SOURCES',
            style: TextStyle(
                color: kTextMuted,
                fontSize: kFontSM,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
        const SizedBox(height: 10),
        for (final c in sources) ...[
          CitationRow(c),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// One source row under "SOURCES": a link icon + label that opens the citation
/// (PubMed / PMC / DOI) in the browser. Textbook citations (no [Citation.url])
/// render as plain, non-tappable text with a book icon.
class CitationRow extends StatelessWidget {
  const CitationRow(this.citation, {super.key});
  final Citation citation;

  @override
  Widget build(BuildContext context) {
    final url = citation.url;
    final hasLink = url != null;
    return GestureDetector(
      onTap: hasLink
          ? () => launchUrl(Uri.parse(url),
              mode: LaunchMode.externalApplication)
          : null,
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(hasLink ? Icons.link : Icons.menu_book_outlined,
              size: 15, color: hasLink ? kAccent : kTextDim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              citation.label,
              style: TextStyle(
                color: hasLink ? kAccent : kTextSubtle,
                fontSize: kFontSM,
                height: 1.4,
                decoration: hasLink ? TextDecoration.underline : null,
                decorationColor: kAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
