# Defensive Publication — Prior Art Disclosure

**Title:** Crediting recorded prior activity toward an exercise warm-up, with heart-rate-gated warm-up termination and audio status through a consumer earbud
**Author / discloser:** Halfmarble LLC (gerard ziemski, Cofounder | Bioenergetics OS Architect)
**Effective publication date:** 2026-06-15 — the date Technical Disclosure Commons posted this disclosure, and its governing prior-art date.
**Status:** Defensive publication — **PUBLISHED**. The method described herein is dedicated to the public domain (see *Dedication*, below).
**TDCommons:** Defensive Publications Series — <https://www.tdcommons.org/dpubs_series/10439> (posted 2026-06-15).

> **Published 2026-06-15.** This disclosure was held private until it could be deposited
> somewhere a patent examiner would actually find it — a defensive publication confers prior-art
> protection only once it is publicly accessible and archived, and a GitHub README is not that.
> The condition set by the hold notice this replaces has been met: it is deposited in the
> Technical Disclosure Commons Defensive Publications Series at
> [dpubs_series/10439](https://www.tdcommons.org/dpubs_series/10439), which is examiner-searched.
>
> The deposited article body is `PRIOR_ART_WARMUP_READINESS_tdcommons.md`; this file is the
> master, and carries additionally the *Where this was published* record below and a note on the
> lighter search behind §C.

---

## Purpose

This document is a **defensive publication**. Its sole purpose is to place the method described below into the public record as **prior art**, so that it remains freely practicable by anyone and **cannot be patented by any third party**.

It is **not** a product description, a license grant for any software, or a statement about the availability or price of any application. It is the warm-up-phase counterpart to the applicant's separately published heart-rate-recovery-gated rest-interval disclosure (`PRIOR_ART_REST_GATING.md`).

**Point of novelty.** A prior-art review (commercial products, patents, and academic literature) found that heart-rate-gated warm-up *termination* and symmetric cool-down gating are already anticipated (see *Closest known prior art*). The element that a review did **not** find anywhere — and the reason this disclosure is worth publishing — is **§A below: crediting recorded prior activity, read from a health-data store, toward shortening or waiving the warm-up.** The remaining elements (§B–§D) are disclosed to secure the specific *combination*, not because each is independently novel.

---

## Scope and what this does *not* do

This dedication applies **only to the method described in this document.** To avoid any ambiguity, this disclosure:

- **Does NOT** dedicate, and is expressly carved out from, the applicant's **retained bioenergetic and motor-control biomarker methods** — including, in particular, **estimation of bioenergetic or metabolic readiness, sustainable intensity, or fitness/fatigue state from the heart-rate response (for example, heart-rate-recovery kinetics) to a preceding activity** — as well as motor-timing-variability versus heart-rate-variability dissociation, bilateral strike-asymmetry indexing, and sustainable-intensity-heart-rate estimation from inertial power decay, which are the subject of separately filed or retained work and are **not** dedicated here. This document dedicates the *warmth-crediting pacing* method, **not** any *readiness or biomarker* inference.
- **Does NOT** dedicate the applicant's broader **closed-loop therapeutic and sensory-cuing methods**, which are outside the scope of this document and unaffected by it.
- **Does NOT** license, assign, or open any **source code**, which is governed separately by its own license.
- **Does NOT** affect the **SteadyHeartBeat application** as a product, or waive any **trademark, brand, trade dress, or copyright** held by Halfmarble LLC.
- **Does NOT** dedicate any method not explicitly described here. Methods halfmarble has chosen to retain (including any not yet implemented or disclosed) are outside the scope of this document.

---

## Disclosure

A method of dynamically determining and gating the warm-up period preceding an exercise session based on **recorded prior activity** and real-time heart rate, rather than a fixed-duration warm-up, with audio status announced through a consumer earbud.

### §A — Prior-activity credit from a recorded activity history (the central method)

The minimum warm-up duration is reduced or waived when the user is determined to have **arrived already warm**, where that determination draws on **previously recorded activity read from a health-data store** — not only on the instantaneous physiological reading at the moment the session begins.

Enabling detail:

- The system queries a platform health-data store (for example Apple HealthKit, Google Fit, or an equivalent) and/or its own session log for **activity bouts ending within a recency window** before the present session — a previously recorded workout (for example a cycling session the user logged immediately before), or elevated active-energy or heart-rate samples obtained from that store.
- The amount of warm-up credited **scales with the recency and intensity** of the corroborated prior activity: a vigorous bout that ended minutes ago credits more (up to waiving the warm-up entirely) than a light bout that ended longer ago.
- A concrete case within scope: **crediting a wearable-detected commute or transfer activity** (for example cycling or walking to the venue, recorded by the phone or watch) toward the warm-up of the subsequent session.
- This is **distinct from** determining warmth from an *instantaneous* sensor reading at session start (which is separately disclosed in §B(a) and is already known — see *Closest known prior art*). §A's distinguishing feature is the use of **logged history with recency/intensity scaling**, applied specifically to **warm-up duration**.

**Expressly excluded from this disclosure (retained):** inferring bioenergetic or metabolic readiness, sustainable intensity, or fitness/fatigue state from the heart-rate *response* to the prior activity. This disclosure covers crediting *warmth* for pacing; it does **not** cover *readiness/biomarker* estimation, which the applicant retains.

### §B — Heart-rate-gated warm-up termination (disclosed as part of the combination)

- At session start the system reads the current heart rate from a consumer in-ear device (or other wearable) and compares it to a personalized warm-up-readiness target computed as a **percentage of an age-derived maximum heart rate** (the age-derived zone configuration itself already being in the public domain per the applicant's separate defensive publication). A **minimum** warm-up duration (floor) ensures adequate warm-up when heart rate rises quickly; a **maximum** warm-up duration (cap) bounds the wait.
- The warm-up phase ends, and the first work interval (or steady effort) begins, when either (1) the current heart rate rises to or above the readiness target and the elapsed warm-up exceeds the minimum, or (2) the maximum warm-up duration elapses (**timeout fallback**).
- (a) **State-based skip:** the warm-up is waived when the heart rate at session start is already at or above the readiness target, sustained for a short confirmation window to exclude transient spikes.

### §C — Audio status through a consumer earbud (disclosed as part of the combination)

- During the warm-up, heart-rate status is announced through the earbud audio channel with **announcement frequency increasing as the user approaches the target** (rather than at a fixed interval); a single **"ready" (or "already warmed up")** announcement upon reaching readiness or upon crediting prior activity per §A; and an indication that the session is **starting with warm-up incomplete** if the timeout fires first.

### §D — Symmetric cool-down (disclosed as part of the combination)

- The same gating is applied symmetrically to the **cool-down** phase, gating *down* to a lower heart-rate target with the same floor/cap and audio behavior.

### Variations within scope

Using a heart-rate slope or trajectory toward the target rather than an absolute threshold; using skin temperature, respiratory rate, or step cadence as corroborating warmth signals (for §A's prior-activity corroboration or §B's live reading); a standalone "warm-up only" mode that announces readiness without committing to a full session; and application to any subsequent gated-interval or steady-state session (for example boxing, cycling, running, or rowing).

---

## Closest known prior art (what a third party would have to design around)

A review located the following references. They are listed so this disclosure can be mapped against them; none anticipates §A.

- **Nike, US 8,287,436 B2** (priority 2002) — scripted workout steps that advance when heart rate enters a percentage range of maximum heart rate. **Anticipates §B's HR-gated termination core.** Does not address prior-activity credit.
- **Samsung, US 12,233,312** (priority 2021) — wearable warm-up screen that switches to the main-exercise screen when a sensed value (body temperature in the claims; heart rate in the specification) reaches a reference, with a minimum-time floor (claim 7) and a symmetric cool-down (claim 11). It waives the warm-up when the **start-of-session** reading is already elevated — i.e., it **infers a prior bout from instantaneous physiology only.** **Anticipates §B(a) state-based skip and §D cool-down.** Does **not** use logged activity history.
- **Philips, CN 105744886 A** — "method of determining a warming-up status" from characteristics of the **live** heart-rate signal. Another instantaneous-sensing reference; does **not** use logged history.
- **Firstbeat / Garmin, US 10,238,915** — uses the warm-up as a **measurement window** to compute a readiness index; training history feeds the readiness *calculation*. The warm-up is an **input**, not an output — it does **not** shorten or adjust warm-up duration. This is the nearest reference in which both "warm-up" and "training history" appear, and the one most worth distinguishing.
- **Under Armour, EP 3 520 068 A1** — weights whole-workout *recommendations* by the **recency** of previously completed workouts. Establishes the recency-credit concept, but applies it to workout selection, **not** to warm-up duration.

**Net:** the bridge between "logged activity history (with recency/intensity scaling)" and "warm-up duration" — §A — was not found in any product, patent, or paper. The most likely examiner attack on a third-party claim to §A would be an *obviousness combination* (e.g., Samsung's warm-up adjustment + Under Armour's recency-weighted history); publishing §A as prior art forecloses a clean novelty claim and supplies the express teaching that an obviousness combination otherwise has to assume.

> The escalating spoken-cue cadence and the warm-up state-machine cues in §C (the "already warmed up" / "starting incomplete" announcements) were also not found in the reviewed art, though the search there was lighter; the generic case of spoken HR cues over an earbud is well-anticipated (adidas miCoach, Garmin audio prompts, Apple Workout Buddy) and is **not** claimed as novel.

---

## Dedication to the public domain (CC0)

To the extent permitted by law, Halfmarble LLC dedicates the **method described in this document** to the **public domain** under the [Creative Commons CC0 1.0 Universal Public Domain Dedication](https://creativecommons.org/publicdomain/zero/1.0/), effective upon its publication. halfmarble waives all patent and other rights it may hold in the described method to the extent necessary to ensure it remains free for anyone to practice. This dedication is irrevocable as to the method described above and does not extend to anything outside the *Scope* section.

---

## Where this is published

A defensive publication blocks a later third-party patent only if a patent examiner can **find**
it. Self-published pages and GitHub READMEs are rarely searched by examiners and are unlikely to
be cited against a competitor's application — which is why this disclosure was held until it could
be deposited properly.

- **Primary — Technical Disclosure Commons**, Defensive Publications Series:
  [dpubs_series/10439](https://www.tdcommons.org/dpubs_series/10439), posted **2026-06-15**. This
  is the deposit that gives the disclosure teeth, and its date is the governing prior-art date.
  Deposited article body: `PRIOR_ART_WARMUP_READINESS_tdcommons.md`.
- **Secondary —** listed in the public repository's `README.md` prior-art section alongside the
  applicant's other disclosures, as a public, timestamped pointer; the signed Git history provides
  an independent dated record.

---

*Halfmarble LLC — [halfmarble.com](https://halfmarble.com) — privacy@halfmarble.com*
