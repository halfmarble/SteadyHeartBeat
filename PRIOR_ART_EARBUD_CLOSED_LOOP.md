# Defensive Publication — Prior Art Disclosure

**Title:** Consumer earbud as a closed-loop biometric sensor and ambient feedback device for exercise support
**Author / discloser:** halfmarble LLC (gerard ziemski, Cofounder | Bioenergetics OS Architect)
**Effective publication date:** 2026-06-04 (the date this document first became publicly accessible)
**Status:** Defensive publication. The methods and techniques described herein are dedicated to the public domain (see *Dedication*, below).
**Permanent archive (DOI):** <https://doi.org/10.5281/zenodo.20510077>

---

## Purpose

This document is a **defensive publication**. Its sole purpose is to place the methods and techniques described below into the public record as **prior art**, so that they remain freely practicable by anyone and **cannot be patented by any third party**.

It is **not** a product description, a license grant for any software, or a statement about the availability or price of any application.

---

## Scope and what this does *not* do

This dedication applies **only to the methods, techniques, and system architectures described in this document.** To avoid any ambiguity, this disclosure:

- **Does NOT** license, assign, or open the SteadyHeartBeat **source code**. The source code is governed separately by its own license file (`LICENSE`). Changing or replacing that license at any time does not affect this disclosure, and this disclosure does not affect that license.
- **Does NOT** affect the **SteadyHeartBeat application** as a product — its distribution, pricing, availability, App Store presence, or any commercial terms. Those remain entirely at halfmarble's discretion.
- **Does NOT** waive any **trademark, brand, trade dress, or copyright** held by halfmarble LLC. `halfmarble`, `SteadyHeartBeat`, and related marks remain the property of halfmarble LLC.
- **Does NOT** dedicate any method not explicitly described here. Methods halfmarble has chosen to retain (including any not yet implemented or disclosed) are outside the scope of this document and are unaffected by it.

In short: the **ideas in this file** are public-domain prior art; the **code** is licensed separately; the **app and brand** are halfmarble's. Each is an independent layer, and a future change to any one of them leaves the others intact.

---

## Disclosure 1 — Consumer earbud as simultaneous biometric sensor and feedback channel

A system in which a single consumer earbud (e.g., an in-ear device with an integrated optical/photoplethysmographic heart-rate sensor) serves **simultaneously** as:

1. the **heart-rate sensor**, and
2. the **sole feedback channel** (audio output),

for real-time exercise support — **without** any separate wearable (smartwatch, chest strap), and **without** requiring the user to look at a screen. The user's hands and eyes remain free.

Enabling detail:

- Heart-rate and related samples (active energy, respiratory rate, step count, distance, flights climbed) are obtained through the host operating system's on-device health/workout framework (e.g., a live workout session and live workout builder), keeping all biometric computation on-device with no transmission off the device.
- **Age-derived heart-rate zone configuration:** maximum heart rate is estimated as `maxHR = 208 − 0.7 × age` (Tanaka et al.), with `age` derived from the platform health store's date-of-birth (computed to the actual birthday, not by calendar-year subtraction). Zone boundaries are placed at 50/60/70/80/90% of `maxHR`, plus a bradycardia floor.
- **Dual-trigger voice announcement logic:** the current value is announced both (a) on a periodic interval and (b) immediately when the value drifts past a configurable delta threshold, where the interval trigger and the delta trigger maintain **independent baselines** so neither suppresses the other.
- **Background-resilient audio:** a native speech synthesizer holds the audio session active for the duration of the activity so spoken feedback continues while the application is backgrounded, ducking other audio rather than interrupting it.
- **Pre-activity cardiovascular readiness snapshot:** resting heart rate, heart-rate variability (SDNN), and VO₂max read from the platform health store and color-coded against clinical reference ranges, with data-freshness timestamps.

## Disclosure 2 — Interface and algorithm techniques

- **Biometric-event-gated animation:** an on-screen numeric value (e.g., beats-per-minute) is repositioned **once per received sensor sample** rather than once per display refresh frame, decoupling animation cadence from the display refresh rate to reduce processor wakeups and power draw while preserving a "live" feel.
- **Orientation-independent overlay position tracking:** the value's drift target is derived from the recent signal trend and clamped within the plotting area, tracking position consistently across device orientations.
- **Trapezoidal time-in-zone integration:** time spent in each heart-rate zone is computed by trapezoidal integration over `(inter-sample interval × zone of the interval's mean value)`, rather than by counting samples, giving duration-accurate zone totals independent of sample rate.
- **Per-unit-resolution, zone-colored post-session histogram:** a post-session histogram of the biometric signal at one-unit (1-BPM) resolution, with each bar colored by the heart-rate zone its value falls into.
- **Landscape on-demand inspection with a value/time scrubber:** a saved-session chart that, on user request, rotates to a wide fullscreen view in which dragging a finger across the chart reveals a crosshair, an intersection marker, and an exact value/elapsed-time readout at the touched position.

---

## Dedication to the public domain (CC0)

To the extent permitted by law, halfmarble LLC dedicates the **methods and techniques described in this document** to the **public domain** under the [Creative Commons CC0 1.0 Universal Public Domain Dedication](https://creativecommons.org/publicdomain/zero/1.0/). halfmarble waives all patent and other rights it may hold in those described methods to the extent necessary to ensure they remain free for anyone to practice.

This dedication is irrevocable as to the methods described above. It does not extend to anything outside the *Scope* section.

---

*halfmarble LLC — [halfmarble.com](https://halfmarble.com) — privacy@halfmarble.com*
