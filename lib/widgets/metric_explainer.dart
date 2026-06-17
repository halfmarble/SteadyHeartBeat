import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants.dart';

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

const Map<String, MetricExplainer> kMetricExplainers = {
  'bedHrv': MetricExplainer('bed HRV', [
    'Bed HRV is the typical (median) heart-rate variability across your whole '
        'night in bed — from when you fall asleep until you get out of bed, '
        'brief wake-ups included.',
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
    'Bed HR is your average heart rate across the same window — your whole night '
        'in bed, from falling asleep to getting out of bed.',
    'It is close to a resting heart rate but taken over the full night, so brief '
        'stirrings nudge it up a little. Lower, steadier nights generally track '
        'with better recovery.',
    'It differs from Apple’s “Resting Heart Rate,” which is '
        'computed a different way, so the two won’t always match. Watch your '
        'own baseline rather than comparing to anyone else.',
    'This is a general wellness reading, not a medical measurement.',
  ], sources: [
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
                    if (info.sources.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      const Text('SOURCES',
                          style: TextStyle(
                              color: kTextMuted,
                              fontSize: kFontSM,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2)),
                      const SizedBox(height: 10),
                      for (final c in info.sources) ...[
                        _CitationRow(c),
                        const SizedBox(height: 10),
                      ],
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

/// One source row under "SOURCES": a link icon + label that opens the citation
/// (PubMed / PMC / DOI) in the browser. Textbook citations (no [Citation.url])
/// render as plain, non-tappable text with a book icon.
class _CitationRow extends StatelessWidget {
  const _CitationRow(this.citation);
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
