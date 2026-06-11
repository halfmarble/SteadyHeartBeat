# Known bugs

Running log of confirmed bugs and their root cause. Newest first.

---

## 1. Ascent announced in meters even when units are set to Imperial

**Status:** ✅ Fixed 2026-06-09. The unit preference is now pushed to native
(`WorkoutService.setUseImperial` → `AppDelegate` → `WorkoutManager`, re-pushed at
each workout start and on toggle). The spoken cue says **feet** when Imperial
(milestones every +100 ft) and **meters** when Metric (every +50 m), so it matches
the on-screen display. Regression-guarded by `test/workout_provider_test.dart`
("unit preference reaches native"). The open question below was resolved as Imperial
**feet** (matching the display), **not** miles — flag if you actually wanted miles.

**Reported:** 2026-06-05 (heard during a real hike, app set to Imperial).

**Symptom:** the spoken ascent milestone cue says "Climbed N meters" regardless of
the Metric/Imperial setting. On-screen ascent already respects the setting (shows
ft), so the voice and the display disagree.

**Root cause:** the ascent milestone cue is composed in the native layer, which has
no knowledge of the Dart-side `useImperial` preference and hardcodes meters:

- `ios/Runner/WorkoutManager.swift:1205`
  `speak(text: "Climbed \(Int(_lastAscentAnnounceMeters)) meters")`
- Milestone step is also metric: `_ascentAnnounceStepMeters = 50` (announce every +50 m),
  `WorkoutManager.swift:137`.

The display path is correct and unit-aware — `fmtElevation(m, imperial)` in
`lib/utils.dart:15` returns `ft` when imperial, `m` otherwise. The native cue never
goes through it.

**Fix direction:**
- Push the unit preference to native at workout start (alongside the other config
  pushed in `workout_provider`), then have `_onAltitude` format the cue as feet when
  imperial: `Int(meters * 3.28084)` ft.
- Make the announce step unit-aware too, so milestones are round numbers in the
  active unit (e.g. every +50 m metric / every +100 or +250 ft imperial) instead of
  every +50 m converted to an odd ft value.

**Open question (from the report):** the note also asked that "ascent > 100 ft be
reported in miles (or a fraction of it)." Ascent is a vertical total; expressing it
in miles is unusual (856 ft ≈ 0.16 mi) and reads oddly. Confirm intent with Gerard —
most likely he wants Imperial **feet** for ascent (matching the display), not miles.
Distance (horizontal) already rolls up to mi via `fmtDist`, `lib/utils.dart:1`.

---

## 2. Boxing icon is inconsistent — sometimes two gloves, sometimes one

**Status:** ✅ Fixed 2026-06-09. Extracted one shared widget,
`lib/widgets/workout_type_icon.dart` (`WorkoutTypeIcon`), that always renders boxing
as the mirrored pair and every other type as its single icon. All sites now route
through it — the three inline pair copies, the one-glove chart-dialog header, and
the hardcoded boxing config-sheet header — and the bare-`sports_mma`/`_iconFor`
mappings were deleted. One source of truth, guarded by
`test/workout_type_icon_test.dart`.

**Reported:** 2026-06-05. Intent: boxing should always show a mirrored **pair** of
gloves (left + right); some screens show only one.

**Root cause:** the "mirrored pair" is implemented inline (a `Stack` of
`Icons.sports_mma` plus a horizontally flipped copy) in three separate places, but
several other surfaces fall through to the plain single-icon mapping, which returns
one `Icons.sports_mma`. There is no shared widget, so coverage is uneven.

Two-glove (pair) sites:
- `lib/screens/home_screen.dart:1248` `_icon()` — size 22, width 38
- `lib/screens/home_screen.dart:2187` workout-type selector — size 19, width 32
- `lib/screens/sessions_screen.dart:717` `_WorkoutIcon` — size kIconMD, width 38

One-glove sites (boxing falls through to the single-icon mapping):
- `lib/screens/sessions_screen.dart:432` — `Icon(_iconFor(widget.type), …)`, bypasses
  the `_WorkoutIcon` pair widget
- `lib/screens/pre_workout_sheet.dart:282` — boxing config sheet header, hardcoded
  single `Icons.sports_mma`
- Mappings that yield one glove for boxing: `_iconFor` (`sessions_screen.dart:167`)
  and `_WorkoutTypeIcon.icon` (`home_screen.dart:2095`)

**Fix direction:** extract a single shared `BoxingGloves`/`WorkoutTypeIcon` widget that
special-cases boxing as the mirrored pair, and route **every** workout-type icon
through it. Remove the three inline copies and stop rendering boxing via the bare
`Icons.sports_mma` mappings (or have those mappings never be reached for boxing). One
source of truth = no more drift.
