import 'package:flutter/material.dart';
import '../constants.dart';

/// Plain-language explainers for the readiness-snapshot metrics, surfaced by the
/// ⓘ affordance on each chip (home screen). Glass Box: the meaning of every
/// number is one tap away — especially important for "bed HRV" / "bed HR", whose
/// values intentionally won't match other apps (different HRV measure + window).
///
/// Keep the copy free of FDA-restricted language ("treat", "diagnose",
/// "prevent", etc.) — these are general-wellness readings under the FDA 2019
/// General Wellness Policy.
class MetricExplainer {
  final String title;
  final List<String> paragraphs;
  const MetricExplainer(this.title, this.paragraphs);
}

const Map<String, MetricExplainer> kMetricExplainers = {
  'bedHrv': MetricExplainer('bed HRV', [
    'Bed HRV is the typical (median) heart-rate variability across your whole '
        'night in bed — from when you fall asleep until you get out of bed, '
        'brief wake-ups included.',
    'We take the median across the full in-bed window so a few restless, '
        'high-movement minutes don’t skew the number.',
    'Watch your own baseline over time — the trend matters more than any single '
        'night, and there is no universal “good” value. Night to night, '
        'a higher reading generally tracks with feeling more recovered.',
    'If you track HRV in another app, expect a different number: many apps use a '
        'different variability measure (rMSSD) over only the deepest part of '
        'sleep, while bed HRV uses SDNN across your full night.',
    'This is a general wellness reading, not a medical measurement.',
  ]),
  'restingHrv': MetricExplainer('resting HRV', [
    'This is your current heart-rate variability (SDNN) — your most recent '
        'reading from Apple Health, or a value you entered yourself.',
    'Once your watch records variability across a night in bed, this becomes '
        '“bed HRV”: the median across your whole night, a steadier '
        'number to track.',
    'This is a general wellness reading, not a medical measurement.',
  ]),
  'bedHr': MetricExplainer('bed HR', [
    'Bed HR is your average heart rate across the same window — your whole night '
        'in bed, from falling asleep to getting out of bed.',
    'It is close to a resting heart rate but taken over the full night, so brief '
        'stirrings nudge it up a little. Lower, steadier nights generally track '
        'with better recovery.',
    'It differs from Apple’s “Resting Heart Rate,” which is '
        'computed a different way, so the two won’t always match. Watch your '
        'own baseline rather than comparing to anyone else.',
    'This is a general wellness reading, not a medical measurement.',
  ]),
  'restingHr': MetricExplainer('resting HR', [
    'This is your current resting heart rate — your most recent reading from '
        'Apple Health, or a value you entered yourself.',
    'Once your watch records heart rate across a night in bed, this becomes '
        '“bed HR”: your average across the whole night.',
    'This is a general wellness reading, not a medical measurement.',
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
    'This is a general wellness estimate, not a medical measurement.',
  ]),
};

/// Presents the explainer for [key] as a bottom sheet. No-op for an unknown key.
Future<void> showMetricExplainer(BuildContext context, String key) async {
  final info = kMetricExplainers[key];
  if (info == null) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
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
                    for (final p in info.paragraphs) ...[
                      Text(
                        p,
                        style: const TextStyle(
                            color: kTextSubtle, fontSize: kFontMD, height: 1.45),
                      ),
                      const SizedBox(height: 12),
                    ],
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
