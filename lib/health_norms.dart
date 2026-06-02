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
