# SteadyHeartBeat

<img align="right" width="120" src="assets/icons/AppIcon.png" alt="SteadyHeartBeat app icon">

iOS app that reads heart rate from AirPods with heart rate monitoring via HealthKit and announces it aloud — no watch, no chest strap, eyes and hands free.

Built by [Halfmarble LLC](https://halfmarble.com) as a proof of concept for ambient on-device biometric feedback, and as a prior art vehicle for the consumer-earbud-as-closed-loop-biometric-sensor pipeline. It was also a testbed for what it actually takes to keep user data protected and never released — to prove we can deliver on the privacy we promise.

**Prior art published: 2026-06-04** — two public-domain defensive publications: **[PRIOR_ART_EARBUD_CLOSED_LOOP.md](PRIOR_ART_EARBUD_CLOSED_LOOP.md)** and **[PRIOR_ART_REST_GATING.md](PRIOR_ART_REST_GATING.md)**.

---

## What it does

- **Voice announcements** — current BPM announced at a configurable interval (continuous / 2s / 5s / 15s / 30s / 1 min) and immediately when HR changes by a configurable threshold (±3 / ±5 / ±8 / ±10 BPM). Both triggers use independent baselines so interval announcements never suppress drift detection.
- **Live chart** — full-session HR history, chart fills the screen, auto-scales to the session's HR range. Chart time axis is at least 15 minutes and grows as the session continues.
- **5-zone color gradient** — the HR line is colored green (Zone 1 recovery) → chartreuse (Zone 2 fat burn) → yellow (Zone 3 aerobic) → deep orange (Zone 4 anaerobic) → red (Zone 5 maximum effort), with quadratic easing in the warning zone. Zone boundaries are computed automatically from your date of birth via the Tanaka formula (maxHR = 208 − 0.7 × age) read from Apple Health.
- **Zone coaching** — optionally name your training zone in each announcement ("142, zone 4"), and with a target zone set, append a steering nudge — "push" when you're below it, "ease off" when above. Composed on-device in the native layer so it keeps coaching while backgrounded with the screen off. Requires heart-rate zones (age or date of birth configured); falls back to the bare number otherwise.
- **Pre-workout readiness snapshot** — shows resting HR, HRV (SDNN), and VO₂ max from Apple Watch (when available), color-coded against **age-banded reference norms** (see [References](#references)), with data freshness timestamps.
- **Live metrics overlay** — current BPM centered on the chart with calories (yellow, right) and breathing rate (blue, left) as subscripts. In portrait, the BPM number drifts 1 px per sensor sample away from the heart rate line. In landscape, it's always dead center.
- **Workout type** — select Boxing 🥊, Cycling 🚴, Running 🏃, or Other before starting. Sets the correct `HKWorkoutActivityType` for Apple Fitness rings. Saving the finished workout to Apple Health is on by default and can be turned off in Preferences (**Apple Health → Save workouts to Apple Health**) — with it off, the workout is discarded and never leaves the device.
- **Boxing round timer** — for boxing workouts, an optional round timer with amateur (3 × 2:00) and pro (12 × 3:00) presets, plus configurable round length, rest length, and round count. Calls rounds and rest aloud through the same voice channel, with an optional "ten seconds" warning before each round ends.
- **Post-workout summary** — max HR, average HR (time-weighted), duration, calories, effort score (avg/maxHR × 100), zone time distribution, and a 1-BPM resolution HR histogram colored by zone.
- **Session history** — every completed session is saved as JSON to the app's Documents directory. Tap the clock icon in the app bar to browse past sessions with mini histograms.
- **Screen wakelock** — screen stays on during monitoring, returns to normal auto-lock when stopped.

---

## Screenshots

<table>
  <tr>
    <td align="center" width="33%"><img src="assets/screenshots/IMG_8601.PNG" alt="Home screen with pre-workout readiness snapshot and workout selector"><br><sub>Pre-workout readiness — resting HRV, resting HR, VO₂ max — then pick a workout type</sub></td>
    <td align="center" width="33%"><img src="assets/screenshots/IMG_8604.PNG" alt="Zone coaching with a target zone selected"><br><sub>Set a target zone and hear "push" / "ease off" coaching as you train</sub></td>
    <td align="center" width="33%"><img src="assets/screenshots/IMG_8603.PNG" alt="Boxing round timer with configurable rounds, rest, and ten-second warning"><br><sub>Boxing round timer — amateur/pro presets, configurable rounds, rest, and "ten seconds" warning</sub></td>
  </tr>
</table>

The full-session HR chart fills the screen, colored by training zone (green recovery → red maximum effort) — turn the phone landscape. Below, the same hike recorded on two people:

<p align="center">
  <img width="760" src="assets/screenshots/IMG_8632.PNG" alt="Landscape heart-rate chart from a real hike with a higher-intensity profile reaching Zone 5"><br>
  <sub>A higher-intensity profile — sustained Zone 4 with Zone 5 peaks (max 150, avg 131)</sub>
</p>

<p align="center">
  <img width="760" src="assets/screenshots/IMG_8645.PNG" alt="Landscape heart-rate chart from the same hike showing a long aerobic effort bookended by two climbs"><br>
  <sub>A long aerobic effort bookended by two climbs (max 128, avg 96, over two hours)</sub>
</p>

---

## Hardware requirement

Requires **AirPods with heart rate monitoring** (AirPods Pro 3 or later) and iOS 26 or later. Heart rate monitoring requires `HKWorkoutSession` on iPhone, which is only available on iOS 26+.

---

## Recommended: install a premium voice

For the clearest spoken readout, install Apple's **Ava (Premium)** voice before your first workout: **Settings → Accessibility → Spoken Content → Voices → English → Ava**, then choose the **Premium** quality (one-time download). SteadyHeartBeat automatically prefers the highest-quality installed voice (premium → enhanced → default), and you can also pick it explicitly in **Preferences → Voice & announcements → Voice**. Without a premium voice the app falls back to the standard system voice, which sounds noticeably more robotic.

---

## Architecture

```
AirPods Pro 3 optical sensor
        │
        ▼
 HKWorkoutSession / HKLiveWorkoutBuilder
 (iOS HealthKit — on-device only)
        │
   ┌────┴────┐
   │         │
 Heart    Respiratory     Active
 rate       rate         calories
   │         │               │
   └────┬────┴───────────────┘
        │
   WorkoutProvider (Dart)
        │
   ┌────┴──────────────────────┐
   │                           │
Voice TTS                  Live chart
(AVSpeechSynthesizer)      + overlay
   │                           │
   └─────────AirPods───────────┘
         (same device)
```

All computation is on-device. No data leaves the iPhone — halfmarble never receives it. Session files are stored in the app's private Documents directory and are explicitly excluded from iCloud/iTunes backup, so they stay on the device.

---

## Prior art, code, and the app — three separate layers

These are deliberately **independent** decisions. A change to one does not affect the others:

1. **Prior art (public domain).** Selected *methods and techniques* are disclosed as dated, public-domain **defensive publications** — **[PRIOR_ART_EARBUD_CLOSED_LOOP.md](PRIOR_ART_EARBUD_CLOSED_LOOP.md)** and **[PRIOR_ART_REST_GATING.md](PRIOR_ART_REST_GATING.md)** (effective 2026-06-04). Publishing them as prior art keeps them freely practicable by anyone and prevents third parties from patenting them. That is their only purpose — they do **not** give away the source code or the application.
2. **Code license.** The *source code* is governed separately by **[LICENSE](LICENSE)**, and may be relicensed in future without affecting the prior-art dedication above.
3. **The application.** *SteadyHeartBeat the product* — its distribution, pricing, and availability — is a halfmarble product decision, independent of the two layers above.

So: the **ideas** are public-domain prior art, the **code** has its own license, and the **app** is a product. Publishing the prior art secures the defensive goal (unpatentability) **without** requiring the app to be free or the code to be open.

---

## Building

Requires a physical iPhone (HealthKit and HKWorkoutSession are unavailable in Simulator). Minimum deployment target: iOS 26.0.

```bash
flutter pub get
flutter run --device-id <your-device-id> --release
```

After changing `ios/Runner/Runner.entitlements`, confirm the HealthKit capability is enabled in Xcode under Signing & Capabilities for both Debug and Release.

---

## References

All physiological thresholds are deterministic and traceable to published science (no opaque models). The metric grading lives in [`lib/health_norms.dart`](lib/health_norms.dart).

- **Max heart rate / zones** — Tanaka formula, `maxHR = 208 − 0.7 × age`. Tanaka H, Monahan KD, Seals DR. *Age-predicted maximal heart rate revisited.* J Am Coll Cardiol. 2001;37(1):153–156. [doi:10.1016/S0735-1097(00)01054-8](https://doi.org/10.1016/S0735-1097%2800%2901054-8)
- **VO₂ max grading** — age- **and sex-banded** norms from the American College of Sports Medicine / Cooper Institute *Aerobics Center Longitudinal Study* (decade percentiles by sex; "excellent" ≈ 80th, "good" ≈ 60th, "fair" ≈ 40th). Biological sex is read from HealthKit (with a manual override in Preferences); it defaults to men's norms when unknown. ACSM. *ACSM's Guidelines for Exercise Testing and Prescription*, 11th ed. Wolters Kluwer; 2021.
- **Resting HRV (SDNN) grading** — age-banded short-term reference ranges (age-only; SDNN sex differences are small and inconsistent). Sammito S, Böckelmann I. *Reference values for time- and frequency-domain heart rate variability measures.* Heart Rhythm. 2016; and short-term (5-min) HRV reference ranges from the **Multi-Ethnic Study of Atherosclerosis (MESA)**. [PMC5010946](https://pmc.ncbi.nlm.nih.gov/articles/PMC5010946/)

---

## Privacy

All processing is on-device — halfmarble never receives your data, and nothing is sent to any server. Your session files and personal health data (age, sex, self-reported conditions, and biometric values) stay in the app's private storage and are excluded from iCloud/iTunes backup. App settings (voice, intervals, units) are the only thing kept in standard preferences.

The one exception is **Apple Health**: by default each finished workout is saved there for your Activity rings, after which it follows your own iCloud Health sync settings. You can turn that off in Preferences (**Apple Health → Save workouts to Apple Health**), and the workout will stay on this device only.

**Your data is yours — locked in is not the goal.** Protecting data this aggressively has a failure mode: it can lock out the owner too. So **Preferences → Your Data** gives you two unconditional actions: **Export My Data** — a complete, readable copy of everything the app stores (sessions and health profile), handed over through the system share sheet to a destination you choose — and **Delete All Data**, which erases it from the device. The export sheet also offers **Anonymize for Research…**, which produces a de-identified copy (random IDs, identity and absolute timestamps stripped) if you choose to donate it. Nothing uploads anywhere; both paths end at the share sheet. The full reasoning — including why a readable export is *more* respectful of ownership than an encrypted one — is in [docs/DATA_PORTABILITY.md](docs/DATA_PORTABILITY.md).

For a complete breakdown of every way data could leave the device and how each is handled — verifiable against the code — see **[DATA_PRIVACY.md](DATA_PRIVACY.md)**. The full privacy policy is at [halfmarble.com/steadyheartbeat/privacy.html](https://halfmarble.com/steadyheartbeat/privacy.html).

---

*Halfmarble LLC — [halfmarble.com](https://halfmarble.com) — privacy@halfmarble.com*
