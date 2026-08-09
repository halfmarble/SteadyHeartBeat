import 'package:flutter/material.dart';
import '../constants.dart';
import '../widgets/metric_explainer.dart';
import '../widgets/app_chrome.dart';

/// "How it works" — the Glass Box science screen, reached from the ⓘ in the home
/// top bar. Explains, with citations, every derived number the app shows: the
/// age-estimated maximum heart rate that everything hangs off, the zones, the
/// ceiling alert, effort, the calorie figure, and elevation. Copy stays
/// inside the FDA General Wellness framing (revised January 2026 — no "treat"/
/// "cure"/"diagnose"/"prevent", no disease names, no diagnostic thresholds).
/// Sources are the same [Citation]s the in-chip explainers cite, rendered with
/// [SourcesBlock].
class HowItWorksScreen extends StatelessWidget {
  const HowItWorksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('How it works'),
        leading: backButton(context),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        children: const [
          Text(
            'Glass Box: every number in SteadyHeartBeat traces back to a formula '
            'and a published source — nothing is a black box. Here’s where each '
            'figure comes from. These are general-wellness readings, not medical '
            'measurements.',
            style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.45),
          ),
          SizedBox(height: 24),
          _ScienceSection(
            title: 'YOUR MAXIMUM HEART RATE',
            paragraphs: [
              'Almost everything else is built on one number: your estimated '
                  'maximum heart rate. We estimate it from your age with the '
                  'Tanaka formula, which is more accurate across adults than the '
                  'old “220 − age” rule.',
              'It’s a population estimate, so your real maximum can sit roughly '
                  'ten beats either side of it. The “max HR” shown after a workout '
                  'is a different thing — that’s the highest rate your AirPods '
                  'actually measured during the session.',
            ],
            formula: 'estimated max HR  =  208 − 0.7 × age',
            sources: [kCiteTanaka],
          ),
          SizedBox(height: 28),
          _ScienceSection(
            title: 'HEART-RATE ZONES',
            paragraphs: [
              'Your zones are five bands set as percentages of that estimated '
                  'maximum. They colour the live chart and the time-in-zone bars '
                  'so you can read your intensity at a glance.',
              'Zone 1 ≥ 50% (light) · Zone 2 ≥ 60% (aerobic) · Zone 3 ≥ 70% '
                  '(tempo) · Zone 4 ≥ 80% (threshold) · Zone 5 ≥ 90% (red-line). '
                  'Below 50 beats per minute is marked as a separate low-rate band.',
              'Percent-of-maximum zones are a coarse guide: they shift if your '
                  'true maximum differs from the age estimate, and anchoring to '
                  'your own measured thresholds is more accurate. Read them as '
                  'rough guidance, not exact targets.',
            ],
            sources: [kCiteTanaka, kCiteAcsmIntensity, kCiteZonesThreshold],
          ),
          SizedBox(height: 28),
          _ScienceSection(
            title: 'THE CEILING ALERT',
            paragraphs: [
              'The ceiling line sits at the bottom of Zone 5 — 90% of your '
                  'estimated maximum — the top of what exercise science calls '
                  'vigorous intensity. When your heart rate crosses it, the app '
                  'can alert you, including in the background.',
              'It’s a deliberately conservative, general-wellness signal that '
                  'you’re near your estimated ceiling — not a personal medical '
                  'limit. Your own safe ceiling depends on your health and any '
                  'medications, so take the alert as a prompt to notice how you '
                  'feel, and ask a clinician about the limits that fit you.',
              'If your age isn’t known, the line falls back to a fixed 175 beats '
                  'per minute.',
            ],
            sources: [kCiteAcsmIntensity, kCiteTanaka],
          ),
          SizedBox(height: 28),
          _ScienceSection(
            title: 'EFFORT',
            paragraphs: [
              'Effort sums up a whole workout in one number: your time-weighted '
                  'average heart rate as a percentage of your estimated maximum.',
              'Because it leans on the age-estimated maximum — and because some '
                  'conditions, including the effect of certain Parkinson’s '
                  'medications on heart rate, blunt the response — read it as a '
                  'rough gauge of how hard a session was, best compared against '
                  'your own past workouts.',
            ],
            formula: 'effort  =  average HR ÷ estimated max HR × 100',
            sources: [kCiteTanaka, kCiteAcsmIntensity],
          ),
          SizedBox(height: 28),
          _ScienceSection(
            title: 'CALORIES (kcal)',
            paragraphs: [
              'The “kcal” figure is Apple Health’s own active-energy estimate for '
                  'the workout, which iOS calculates from your heart rate, '
                  'movement, and body metrics. We show it unchanged — it’s the one '
                  'number here we don’t compute ourselves, and Apple’s exact '
                  'method is its own. Like every wearable calorie estimate it’s an '
                  'approximation, so follow the trend rather than any single value.',
            ],
          ),
          SizedBox(height: 28),
          _ScienceSection(
            title: 'ELEVATION',
            paragraphs: [
              'Elevation is how much altitude you climbed during a workout, read '
                  'from the iPhone’s barometer — the change in air pressure as you '
                  'go up. It’s the relative ascent across the session, not your '
                  'height above sea level, and it uses no GPS.',
            ],
          ),
          SizedBox(height: 28),
          _ScienceSection(
            title: 'BED HRV',
            paragraphs: [
              'Bed HRV is the typical (median) heart-rate variability across your '
                  'night — a rough read on recovery. It uses the SDNN measure over '
                  'your whole in-bed window, so it won’t match apps that use rMSSD '
                  'over deep sleep only. From a consumer watch it’s a guide, not a '
                  'lab measurement — follow your own trend, not any single night.',
            ],
            sources: [
              Citation(
                  'HRV reference ranges — MESA (Multi-Ethnic Study of Atherosclerosis)',
                  'https://pmc.ncbi.nlm.nih.gov/articles/PMC5010946/'),
              Citation(
                  'Consumer-watch SDNN validity — Hsu et al., Eur Heart J Digit '
                  'Health 2023',
                  'https://pubmed.ncbi.nlm.nih.gov/37265873/'),
            ],
          ),
          SizedBox(height: 28),
          _ScienceSection(
            title: 'BED HR',
            paragraphs: [
              'Bed HR is your average heart rate across the same overnight window '
                  '— close to a resting heart rate, but taken over the whole '
                  'night, so brief stirrings nudge it up. Lower, steadier nights '
                  'generally track with better recovery. It’s computed differently '
                  'from Apple’s “Resting Heart Rate,” so the two won’t always match '
                  '— watch your own baseline.',
            ],
            sources: [
              Citation(
                  'Resting-HR reference ranges — Quer et al., PLOS ONE 2020 '
                  '(n=92,457)',
                  'https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0227709'),
              Citation('Apple Watch resting-HR accuracy (peer-reviewed validation)',
                  'https://pmc.ncbi.nlm.nih.gov/articles/PMC11478500/'),
            ],
          ),
          SizedBox(height: 28),
          _ScienceSection(
            title: 'VO₂ MAX',
            paragraphs: [
              'VO₂ max estimates how efficiently your body uses oxygen during '
                  'exercise — a broad marker of cardio fitness. We read it straight '
                  'from Apple Health, which only refreshes it from outdoor walks, '
                  'runs, or hikes with GPS and heart rate lasting around 20 '
                  'minutes, so the date can read months old. It’s an estimate from '
                  'everyday workouts, not a lab test — follow the trend, not the '
                  'exact number.',
            ],
            sources: [
              Citation('VO₂ max fitness norms — ACSM’s Guidelines for Exercise '
                  'Testing & Prescription, 11th ed. (2021)'),
              Citation('Apple Watch VO₂ max validity — PLOS ONE 2025',
                  'https://pubmed.ncbi.nlm.nih.gov/40373042/'),
            ],
          ),
          SizedBox(height: 24),
          Text(
            'SteadyHeartBeat is a general-wellness and fitness tool under the '
            'FDA’s General Wellness policy. The numbers here are for everyday '
            'fitness insight, not medical measurements.',
            style: TextStyle(color: kTextDim, fontSize: kFontCaption, height: 1.4),
          ),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// One titled block on the "How it works" screen: a section header, body
/// paragraphs, an optional boxed formula, and the cited [SourcesBlock].
class _ScienceSection extends StatelessWidget {
  const _ScienceSection({
    required this.title,
    required this.paragraphs,
    this.formula,
    this.sources = const [],
  });
  final String title;
  final List<String> paragraphs;
  final String? formula;
  final List<Citation> sources;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                color: kTextLabel,
                fontSize: kFontBase,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2)),
        const SizedBox(height: 10),
        for (final p in paragraphs) ...[
          Text(p,
              style: const TextStyle(
                  color: kTextSubtle, fontSize: kFontBase, height: 1.45)),
          const SizedBox(height: 10),
        ],
        if (formula != null) ...[
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(formula!,
                style: const TextStyle(
                    color: kTextBright, fontSize: kFontBase, height: 1.4)),
          ),
          const SizedBox(height: 12),
        ],
        SourcesBlock(sources),
      ],
    );
  }
}
