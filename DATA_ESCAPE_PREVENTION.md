# Data-Escape Prevention — Developer Guide

This is the companion to [DATA_PRIVACY.md](DATA_PRIVACY.md). That document tells
*users* what we promise; this one tells *developers and contributors* how those
promises are enforced in code, **what to check before you ship a change**, and
**what to test** so the guarantees can't quietly regress.

If you are reviewing a PR, jump to [The review checklist](#the-review-checklist).
If you are adding a feature that touches health data, read the whole thing.

---

## 1. The threat model: what "escape" means here

We treat health data as having **escaped** the moment it leaves the app's private
on-device storage by any channel the app controls. The protected data is: live
and recorded heart rate, calories, respiratory rate, HRV, VO₂max, resting heart
rate, body weight, age, biological sex, and self-reported conditions.

The channels an app like this can leak through — our complete attack surface:

| # | Channel | How data escapes through it |
|---|---------|------------------------------|
| 1 | **Network** | The app (or a dependency) makes an HTTP/socket call to a server |
| 2 | **Third-party SDKs** | Analytics / crash / ads libraries phone home on their own |
| 3 | **Device backup** | iOS sweeps app storage into iCloud/iTunes backups by default |
| 4 | **Cross-device sync** | iCloud, CloudKit, App Groups, NSUbiquitousKeyValueStore |
| 5 | **Logs** | `print`/`NSLog`/`os_log` of health values, captured by sysdiagnose |
| 6 | **Clipboard / share sheet** | User-or-code-initiated copy/share moves data out of the sandbox |
| 7 | **System donations** | Siri, Spotlight, Handoff, Shortcuts indexing |
| 8 | **Audio / screen** | The spoken readout (inherent), screenshots, screen recording |

Two channels are **inherently outside the app's control** and are documented as
such rather than "fixed": the spoken heart-rate readout (the app's entire
purpose) and Apple-platform features the *user* owns (their iCloud account,
system crash diagnostics, the moment they choose to save to Apple Health).

The guiding rule, from the halfmarble Data-Sovereignty principle: **the user owns
their data and we are its steward, not its owner.** Escape is anything that moves
data without the user's deliberate choice. (Note the corollary: a *deliberate* user choice to export
their own data is **not** escape — it is the user exercising ownership.)

---

## 2. Channel-by-channel: what we did and what to check

### Channel 1 — Network: keep the binary networkless

**What we did.** The app contains zero networking code: no `URLSession`, no
`Network` framework, no HTTP client, no socket. There is no `NSAppTransportSecurity`
exceptions dictionary in `Info.plist` (so ATS blocks cleartext by default — but
the real guarantee is that nothing tries to connect at all).

**The one near-miss to understand:** `url_launcher` *can* open URLs, but we use it
only to hand a URL to the OS — `app-settings:` (opens iOS Settings) and a static
`https://halfmarble.com/...` link the user taps (opens their browser). It never
transmits app data. See `lib/screens/preferences_screen.dart:748,1314` and
`lib/screens/home_screen.dart:1119`. **If you add a `launchUrl` call, the URL must
be static** — never interpolate session or health values into it.

**What to check on every change:**
- No new import of an HTTP client, socket, or the `Network` framework.
- Any new `launchUrl`/deep-link URL is a compile-time constant, not built from data.

### Channel 2 — Third-party SDKs: a build-blocking allowlist

**What we did.** No analytics, ads, or crash-reporting SDK is embedded. To stop
one slipping in during future work, `test/data_privacy_test.dart` holds a
**hardcoded allowlist** of vetted packages and **fails the build** if `pubspec.yaml`
ever lists a dependency not on it. The current allowlist: `flutter`,
`cupertino_icons`, `shared_preferences`, `provider`, `fl_chart`, `path_provider`,
`wakelock_plus`, `url_launcher`, `share_plus`. (`share_plus` is the most recent
addition: it presents the OS share sheet for the user-initiated data export, vetted
local-only with no network access of its own; it went on the list with that
justification, exactly the process below.)

**What to check when adding a dependency:**
1. Does it open a socket, load remote config, or report crashes? If yes, **stop** —
   find a local alternative.
2. Does it pull transitive native SDKs (check the Podfile.lock diff)?
3. Only after you've confirmed it cannot exfiltrate, add it to the allowlist in
   the test — and explain why in the PR.

The test failing is the *designed* behavior, not an obstacle. A red build forces
the conversation.

### Channel 3 — Device backup: exclude every health store

**What we did.** iOS includes app Documents in iCloud/iTunes backups by default.
Both file-backed health stores live in directories explicitly marked
**excluded-from-backup** via a native `excludeFromBackup` method channel:
- Workout sessions → `Documents/sessions/` (`lib/services/session_storage_service.dart:19-26`)
- Health profile → `Documents/private/health_profile.json` (`lib/services/health_profile_store.dart:22-28`)

The exclusion flag is set through `lib/services/backup_exclusion.dart`, implemented
natively in `ios/Runner/AppDelegate.swift`. Crucially, the directory must exist and
be flagged **before** the first write.

**The subtle one — NSUserDefaults is backed up.** `shared_preferences` maps to
NSUserDefaults, which *is* in device backups. So health data must **never** live in
`shared_preferences`. Only non-health settings (voice, intervals, units, the Apple
Health toggle) belong there. Earlier builds violated this; the app now migrates
those keys into the excluded store at launch and purges the backed-up copies
(`lib/providers/workout_provider.dart`, the `_stripLegacyHealthPrefs` path around
`:695-710`).

**What to check:**
- Any new file holding health data is written under an excluded directory, and the
  directory is flagged *before* the first write.
- No health value is ever passed to `SharedPreferences.set*`. If you add a setting,
  ask: is this health data? If yes → `HealthProfileStore`, not prefs.

### Channel 4 — Cross-device sync: none of it

**What we did.** No iCloud document storage, no CloudKit, no
`NSUbiquitousKeyValueStore`, no App Groups, no shared container. The backup
exclusion (Channel 3) also keeps the files out of the only sync path iOS would
otherwise use.

**What to check:** no new entitlement for iCloud/CloudKit/App Groups; no shared
app-group container introduced for "convenience."

### Channel 5 — Logs: compile health values out of release builds

**What we did.** During development the app prints HR values; in release builds
those statements are gated behind `if (kDebugMode)` so they are compiled out
entirely (`lib/providers/workout_provider.dart:919-920`). Service-layer
`debugPrint` calls log *errors*, not health values, and `debugPrint` is itself
throttled/suppressed in release.

**What to check:** never `print`/`debugPrint`/`os_log` a BPM, weight, age, or any
biometric outside a `kDebugMode` guard. Log the *event* ("session saved"), not the
*value*.

### Channel 6 — Clipboard & share sheet: clipboard never, share sheet only for export

**What we did.** The app never uses the system clipboard. It uses the share sheet in
exactly one place: the user-initiated **Export My Data** action
(`lib/services/export_service.dart`), which writes a plaintext copy of the user's own
data to a temp file and presents the share sheet so they can take it off-device. This
is intended, documented egress (the owner exercising ownership — a deliberate
export is not an "escape"), not a leak. It fires only on the button tap and uploads nothing.

**What to check:** any *new* use of the share sheet must likewise be explicit and
user-initiated, and `DATA_PRIVACY.md` must be updated in the same change (the export
is documented in its section 9). Never add `Clipboard.setData` with health values,
and never invoke the share sheet automatically.

### Channel 7 — System donations: not used

**What we did.** No Siri/Shortcuts donations, no Spotlight `NSUserActivity`
indexing, no Handoff. These quietly surface data to system indexes that may sync.

**What to check:** no `NSUserActivity` becoming `eligibleForSearch`/`Handoff` with
health content; no `INInteraction` donations.

### Channel 8 — Apple Health (the *intended*, user-controlled egress)

**What we did.** Saving a finished workout to Apple Health is **on by default but
optional**. When the toggle is off, the native layer calls `discardWorkout()` so
nothing is written to HealthKit and nothing can sync out via the user's iCloud
Health (`ios/Runner/WorkoutManager.swift`, `stopWorkout()` around `:1095-1103`).
The flag is re-pushed to the native singleton on every `start()` so a fresh process
honors it.

This is the model for *all* intended egress: **off-by-policy or explicitly
user-chosen, reversible, and documented.** Once data is in Apple Health it follows
the *user's* iCloud settings — their data, their choice.

**What to check:** the toggle's default and behavior are covered by tests (below);
if you touch the save/discard path, keep those green.

---

## 3. What to test

Two test files carry the privacy guarantees. Treat them as executable spec — if you
change behavior, change the test deliberately and explain why; never delete an
assertion to make a build pass.

### `test/data_privacy_test.dart`
1. **Health data never reaches backed-up preferences.** Edits every one of the ~11
   health keys, then asserts none of them appear in `shared_preferences`.
   *(The single most important regression guard.)*
2. **Migration is loss-safe.** If the excluded store is unavailable, legacy health
   data is retained, never dropped.
3. **Apple Health toggle is honored.** Defaults on; persists; is re-pushed to native
   on `start()` so a fresh native singleton picks it up.
4. **Dependency canary.** The build-blocking allowlist described in Channel 2.

### `test/storage_backup_test.dart`
1. **Stores round-trip.** `HealthProfileStore` and `SessionStorageService` read back
   what they write.
2. **Backup-exclusion flag is actually applied** to each private directory (the
   `excludeFromBackup` channel is invoked).
3. **Exclusion is deduplicated** — marked once per launch, not on every write.
4. **Migration happy-path** — health data is copied into the excluded store, the
   backed-up copies are purged, and non-health settings survive.

### Patterns to follow when you add a test
- **Assert the negative.** "Key X is *absent* from prefs" catches leaks that "key Y
  is present in the store" never will. The strongest privacy test asserts that data
  is *not* somewhere.
- **Test the migration, not just the steady state.** Most leaks we found were in the
  "data written by an older version" path, not the fresh-install path.
- **Make the dangerous-default fail loudly.** The dependency canary is a unit test,
  not a doc — copy that pattern for any "must not regress" invariant.

### What only a real build can verify (call these out in review)
- The native `discardWorkout()` path when the Apple Health toggle is off.
- That `kDebugMode`-gated logging is genuinely absent from the release binary.

Run before pushing: `flutter test` (unit guards) and, for HealthKit-touching
changes, a manual run on a **physical iPhone** (the Simulator has no HealthKit, per
[CLAUDE.md](CLAUDE.md)).

---

## 4. The review checklist

For any PR, the reviewer (and author) should be able to answer **yes** to all that
apply:

- [ ] No new networking code, and any `launchUrl` URL is a static constant.
- [ ] No new dependency — or, if there is one, it cannot exfiltrate and it's been
      added to the allowlist with a justification.
- [ ] No health value written to `shared_preferences` / NSUserDefaults.
- [ ] Any new file of health data lives under a backup-excluded directory, flagged
      before first write.
- [ ] No new iCloud/CloudKit/App Group/Spotlight/Siri/Handoff surface.
- [ ] No health value logged outside a `kDebugMode` guard.
- [ ] No clipboard or share-sheet use with health data (unless it's a deliberate,
      documented, user-initiated export — see DATA_PORTABILITY.md).
- [ ] `test/data_privacy_test.dart` and `test/storage_backup_test.dart` still pass,
      and any new invariant has its own assertion.
- [ ] If user-facing data handling changed, **DATA_PRIVACY.md was updated in the same
      PR.** The user-facing promise and the code must move together.

---

## 5. Why we go this far

The data is valuable *because* it stays private and on-device — that's the product
thesis (a building block toward OpenBioenergyGauge) and the halfmarble
Data-Sovereignty principle. Privacy that's asserted in a README but not enforced in
code rots on the first refactor. The point of the allowlist test, the
backup-exclusion tests, and this checklist is that the guarantees survive
contributors who never read the README — including future us.

*Questions? privacy@halfmarble.com.*
</content>
</invoke>
