# Defensive Publication — Prior Art Disclosure

**Title:** Heart-rate-recovery-gated rest-interval timing with audio status updates through a consumer earbud
**Author / discloser:** halfmarble LLC (gerard ziemski, Cofounder | Bioenergetics OS Architect)
**Effective publication date:** 2026-06-02 (the date this document first became publicly accessible)
**Status:** Defensive publication. The method described herein is dedicated to the public domain (see *Dedication*, below).
**Permanent archive (DOI):** <https://doi.org/10.5281/zenodo.20510165>

---

## Purpose

This document is a **defensive publication**. Its sole purpose is to place the method described below into the public record as **prior art**, so that it remains freely practicable by anyone and **cannot be patented by any third party**.

It is **not** a product description, a license grant for any software, or a statement about the availability or price of any application.

---

## Scope and what this does *not* do

This dedication applies **only to the heart-rate-recovery-gated rest-interval method described in this document.** To avoid any ambiguity, this disclosure:

- **Does NOT** dedicate, and is expressly carved out from, the applicant's **retained motor-control and bioenergetic biomarker methods** — including motor-timing-variability versus heart-rate-variability dissociation, bilateral strike-asymmetry indexing, and sustainable-intensity-heart-rate estimation from inertial power decay — which are the subject of a separately filed patent application and are **not** dedicated here.
- **Does NOT** dedicate the applicant's broader **closed-loop therapeutic and sensory-cuing methods** (the subject of ongoing work), which are outside the scope of this document and unaffected by it. This document dedicates only the specific heart-rate-recovery rest-gating method below.
- **Does NOT** license, assign, or open any **source code**, which is governed separately by its own license.
- **Does NOT** affect the **SteadyHeartBeat application** as a product, or waive any **trademark, brand, trade dress, or copyright** held by halfmarble LLC.
- **Does NOT** dedicate any method not explicitly described here. Methods halfmarble has chosen to retain (including any not yet implemented or disclosed) are outside the scope of this document.

---

## Disclosure — Heart-rate-recovery-gated rest interval with audio status updates

A method of dynamically gating the rest interval between exercise rounds based on real-time heart-rate recovery rather than on a fixed-duration timer, with audio feedback announcing the remaining recovery distance through a consumer earbud.

Enabling detail:

- At the end of each round, the system records the round-end heart rate and computes a personalized recovery target as a percentage of an age-derived maximum heart rate (the age-derived zone configuration itself being already in the public domain per the applicant's separate defensive publication). A minimum rest duration prevents excessively short rests when heart rate drops rapidly; a maximum rest duration prevents excessively long rests when heart rate does not recover.
- The next round begins when either (1) the current heart rate falls to or below the recovery target and the elapsed rest exceeds the minimum, or (2) the maximum rest duration elapses (timeout fallback).
- During the rest interval, heart-rate status is announced through the earbud audio channel with announcement frequency increasing as the user approaches the target (for example, every 30 s when far from target, every 15 s when near, and a single "ready" announcement upon reaching target). If the timeout fires before the target is reached, the system announces that the next round is starting with recovery incomplete.
- Variations within scope: using a heart-rate recovery slope rather than an absolute target; using a heart-rate-variability or respiratory-rate recovery criterion; per-round adaptive adjustment of the recovery percentage as cumulative fatigue rises; application to non-striking interval training (rowing, cycling, running intervals); session termination after a configured number of consecutive timeout events; and announcing an estimated time-to-target derived from the current rate of heart-rate change.

---

## Dedication to the public domain (CC0)

To the extent permitted by law, halfmarble LLC dedicates the **method described in this document** to the **public domain** under the [Creative Commons CC0 1.0 Universal Public Domain Dedication](https://creativecommons.org/publicdomain/zero/1.0/). halfmarble waives all patent and other rights it may hold in the described method to the extent necessary to ensure it remains free for anyone to practice. This dedication is irrevocable as to the method described above and does not extend to anything outside the *Scope* section.

---

*halfmarble LLC — [halfmarble.com](https://halfmarble.com) — privacy@halfmarble.com*
