import 'package:flutter/material.dart';

// ── Brand ─────────────────────────────────────────────────────────────────────
const Color kBackground  = Color(0xFF0D0D0D);
const Color kAccent      = Color(0xFFE84855);
const Color kSurface     = Color(0xFF1A1A1A);
const Color kSurfaceDark = Color(0xFF111111);  // deeper card / nested container
const Color kStopButton  = Color(0xFF2A2A2A);
const Color kSummaryBg   = Color(0xFF0A0A0A);
const Color kErrorBorder = Color(0xFF3A1A1A);

// ── Notification surfaces ─────────────────────────────────────────────────────
// Backgrounds for the in-app SnackBars and the AirPods warning dialog.
// Kept dark and saturated so they read as a clear "alert" against the bg
// without taking over the screen.
const Color kErrorSnackBg   = Color(0xFF8B0000);  // red — save failures, hard errors
const Color kWarningSnackBg = Color(0xFF5C4500);  // amber-brown — non-blocking warnings
const Color kDialogBg       = Color(0xFF1A1500);  // amber-brown — AirPods warning dialog body
const Color kDialogBgLight  = Color(0xFF252000);  // amber-brown — AirPods dialog ⓘ icon row

// ── Text shades ───────────────────────────────────────────────────────────────
const Color kTextBright = Color(0xFFCCCCCC);  // primary body text in dark UI
const Color kTextMuted  = Color(0xFFAAAAAA);
const Color kTextLabel  = Color(0xFF888888);
// Bumped from #666666 to #999999 (WCAG AA fail → ~6.6:1 pass) — kTextSubtle
// is used for body copy in too many places to risk failing contrast for users
// with low vision or in sunlight.
const Color kTextSubtle = Color(0xFF999999);
const Color kTextDim    = Color(0xFF666666);  // was #555555 — slightly brighter for borderline body usage
// Bumped from #444444 to #888888 (≥4.5:1) — used in About section and the
// sessions empty-state body, so must pass AA.
const Color kTextFaint  = Color(0xFF888888);
const Color kTextGhost  = Color(0xFF555555);  // truly decorative — empty-state icons
const Color kChartGrid  = Color(0xFF222222);
// Synthesized "summary index" charts (recovery, sleep quality, activity load,
// strain…) draw in a neutral white/grey rather than a zone hue, so the derived
// 0–100 folds read as composites apart from the directly-measured (coloured)
// metric charts.
const Color kSynthLine  = Color(0xFFCFCFCF);

// ── HR zones ──────────────────────────────────────────────────────────────────
const Color kZoneBrady = Color(0xFFE84855); // <50 bpm  (same as kAccent)
const Color kZone1     = Color(0xFF44CC55); // 50–59 %  light aerobic
const Color kZone2     = Color(0xFF9CCC20); // 60–69 %  aerobic
const Color kZone3     = Color(0xFFFFD000); // 70–79 %  tempo
const Color kZone4     = Color(0xFFFF6D00); // 80–89 %  threshold
const Color kZone5     = Color(0xFFE84855); // 90+ %    red-line (same as kAccent)
// Amber transition between brady (red) and Zone 1 (green). Used as the band
// fill for the bradycardia→Zone 1 stretch and as a lerp endpoint in the
// stroke colour gradient. Lives in the palette so changing the zone visual
// language doesn't require chasing literals across the chart code.
const Color kZoneTransition = Color(0xFFFF8C00);
const Color kCyan      = Color(0xFF4FC3F7); // distance / effort chip

// ── Trends chart palette ────────────────────────────────────────────────────
// Four semantic line colours for the measured-data trend charts (the
// synthesized summary folds use kSynthLine). Collapsed from the old six-colour
// set so colour carries meaning: red = heart, yellow = calories/activity,
// blue = oxygen/respiration, green = sleep/overnight.
const Color kHeartLine    = kAccent; // HRV, HR, resting/walking HR, HR range
const Color kActivityLine = kZone3;  // steps, distance, calories, exercise min
const Color kOxygenLine   = kCyan;   // blood oxygen, breathing rate, VO₂ max
const Color kSleepLine    = kZone1;  // sleep duration, naps, restlessness, temp

// Alpha used for the chart's HR-zone band fills (~7% = subtle background tint
// that doesn't compete with the line). Pulled out so legibility can be tuned
// in one place if needed.
const int kAlphaZoneBand = 0x11;

// [brady, z1, z2, z3, z4, z5] — index matches the zoneSecs list from native
const List<Color> kZoneColors = [kZoneBrady, kZone1, kZone2, kZone3, kZone4, kZone5];

/// Maps an absolute BPM to its HR-zone colour, matching the band identities of
/// the live [BpmChart] gradient. Shared by the live post-workout histogram and
/// the saved-session histograms so a session looks identical wherever it's
/// drawn. Missing boundaries fall back to the next-lower boundary, then to
/// [dangerFallback] (kDefaultDangerBpm by default) — the same chain the chart's
/// danger line uses, so the colour break and the danger line always agree.
Color hrZoneColor(
  double bpm, {
  int? zone1End,
  int? zone2Start,
  int? zone3Start,
  int? zone4Start,
  int? zone5Start,
  int dangerFallback = kDefaultDangerBpm,
}) {
  final brady = kBradycardiaThreshold.toDouble();
  final z1 = zone1End?.toDouble()   ?? brady;
  final z2 = zone2Start?.toDouble() ?? z1;
  final z3 = zone3Start?.toDouble() ?? z2;
  final z4 = zone4Start?.toDouble() ?? dangerFallback.toDouble();
  final z5 = zone5Start?.toDouble() ?? dangerFallback.toDouble();
  if (bpm <= brady) return kZone5; // bradycardia → red
  if (bpm >= z5)    return kZone5;
  if (bpm >= z4) {
    final t = ((bpm - z4) / (z5 - z4).clamp(1.0, double.infinity)).clamp(0.0, 1.0);
    return Color.lerp(kZone4, kZone5, t * t)!;
  }
  if (bpm >= z3) return kZone3;
  if (bpm >= z2) return kZone2;
  if (bpm >= z1) return kZone1;
  return kZone1;
}

// ── Behaviour ─────────────────────────────────────────────────────────────────
const int kBradycardiaThreshold = 50; // bpm below which is bradycardia
// Danger-zone fallback when no age-derived zone5Start (90% max HR) is available.
// Single source of truth so the histograms and the chart's danger line agree.
const int kDefaultDangerBpm = 175;
// Samples in the chart's moving-average smoothing window. Shared by the live
// chart (WorkoutProvider) and the saved-session replay so both lines match.
const int kSmoothWindow = 3;
const int kNoDataTimeoutSeconds = 15;
// Mid-workout HR-stream silence threshold. AirPods Pro 3 push samples every
// ~5 s; 30 s without one means the buds dropped, were removed, or the sensor
// lost lock. Soft warning (we don't stop the workout — signal often resumes).
const int kHrSilenceTimeoutSeconds = 30;
// Physiologically plausible HR bounds for adults. Samples outside this range
// are sensor glitches that would otherwise corrupt min/max/zone-time math.
const double kHrMinBpm = 30.0;
const double kHrMaxBpm = 220.0;

// ── Layout ────────────────────────────────────────────────────────────────────
const double kButtonHeight = 56;
const double kButtonRadius = 12;
const double kCardRadius   = 14;

// ── Typography ────────────────────────────────────────────────────────────────
const double kFontXS      = 9.0;   // chip labels, secondary meta
const double kFontSM      = 10.0;  // zone labels, axis ticks
const double kFontCaption = 11.0;  // footnotes, hint text, zone-time labels
const double kFontBase    = 12.0;  // timestamps, captions
const double kFontMD      = 13.0;  // body / hint text
const double kFontLG      = 15.0;  // card titles, primary labels
const double kFontXL      = 16.0;  // section headings, dialog titles
const double kFontStat    = 18.0;  // stat chip values
const double kFontBtn     = 17.0;  // button labels
const double kFontDisplay = 26.0;  // large metric values (HRV, resting HR, VO₂)

// ── Spacing ───────────────────────────────────────────────────────────────────
const double kSpaceXS  = 4.0;
const double kSpaceSM  = 6.0;
const double kSpaceMD  = 8.0;
const double kSpaceLG  = 10.0;
const double kSpaceXL  = 12.0;
const double kSpaceXXL = 16.0;
const double kSpaceMax = 20.0;

// ── Icon sizes ────────────────────────────────────────────────────────────────
const double kIconXS   = 16.0;  // inline / trailing action icons
const double kIconSM   = 20.0;  // dismissible backgrounds, secondary UI
const double kIconMD   = 22.0;  // card header icons
const double kIconLG   = 48.0;  // empty-state illustrations

// ── Alpha (0x00–0xFF) ─────────────────────────────────────────────────────────
const int kAlphaLow      = 0x28;  // very subtle fills (button hover)
const int kAlphaMid      = 0x44;  // borders, tinted backgrounds
const int kAlphaMuted    = 0xAA;  // secondary color variants
const int kAlphaHigh     = 0xBB;  // zone labels, prominent secondary

// ── Opacity (0.0–1.0) ─────────────────────────────────────────────────────────
const double kOpacityDisabled = 0.35;  // greyed-out / inactive elements
const double kOpacityMuted    = 0.38;  // selector disabled overlay
