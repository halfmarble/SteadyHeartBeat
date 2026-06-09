# Data Privacy

SteadyHeartBeat is built so your health data stays yours. It's read and
processed entirely on your iPhone, halfmarble never receives it, and the app
makes no network requests at all. This document explains exactly what that means
— every way data could conceivably leave your device, and what we do about each.
Because the app is open source, you can verify every claim here against the code
(file references are included throughout).

## What "stays on your device" means

We treat your data as escaping if it leaves the app's private storage by any
channel the app controls: the network, third-party SDKs, device backup,
cross-device sync, shared storage, logs, or the clipboard. The data we protect:
live and recorded heart rate, calories, respiratory rate, HRV, VO₂max, resting
heart rate, body weight, age, biological sex, and any health conditions you
enter.

Two things are inherently outside the app's control and noted under
[What we can't control](#what-we-cant-control): the spoken heart-rate readout
(the app's whole purpose is to say it aloud), and Apple-platform features you
manage yourself (your iCloud account, system crash diagnostics).

## At a glance

| Channel | Status |
|---------|--------|
| Network calls (the app contacting any server) | ✅ None — the app has no networking code |
| Third-party analytics / crash-reporting SDKs | ✅ None |
| Session files in iCloud/iTunes backup | ✅ Excluded from backup |
| Health profile (age, sex, conditions, metrics) in backup | ✅ Excluded from backup |
| Saving workouts to Apple Health | ⚙️ Optional — on by default, can be turned off |
| Heart-rate values in device logs | ✅ Removed from release builds |
| Exporting a copy of your own data | ⚙️ Only when you tap **Export My Data** |
| Clipboard | ✅ Not used |
| Share sheet | ⚙️ Used only for the export you start |
| Siri / Spotlight / Handoff / App Groups / Widgets | ✅ Not used |
| Spoken heart-rate readout | ⚠️ Audible by design |

---

## 1. The app makes no network requests

There is no networking code in the app, and none of its components contact a
server. Its dependencies — `shared_preferences`, `provider`, `fl_chart`,
`path_provider`, `wakelock_plus`, `url_launcher`, `share_plus`,
`cupertino_icons` — are all local. `url_launcher` is used only to open the iOS
Settings app and a static halfmarble web link in your browser; `share_plus` only
presents the system share sheet when you tap **Export My Data** (section 9).
Neither sends app data anywhere on its own.

To keep it that way, an automated test (`test/data_privacy_test.dart`) checks
the project's dependency list against a vetted allowlist and **fails the build**
if any new dependency is ever added — so a networking or analytics library can't
slip in unnoticed during future development.

The app's `PrivacyInfo.xcprivacy` manifest declares no tracking and no collected
data types.

## 2. No analytics or crash-reporting SDKs

The app embeds no analytics, advertising, or crash-reporting SDK (no Firebase,
Sentry, Crashlytics, or similar). Crashes are reported only through Apple's
standard, user-controlled diagnostics — see [below](#what-we-cant-control).

## 3. Workout history is excluded from device backup

Completed workouts are saved as files in the app's private storage on your
iPhone, for the Sessions history screen. By default, iOS includes app storage in
iCloud and iTunes device backups — so we explicitly mark this folder
**excluded from backup**. Your workout history stays on the device.

Code: `lib/services/session_storage_service.dart`,
`lib/services/backup_exclusion.dart`, `ios/Runner/AppDelegate.swift`.

## 4. Your health profile is excluded from device backup

Your age, biological sex, any self-reported conditions, manually entered metrics
(HRV, VO₂max, resting heart rate, weight), and your computed heart-rate zones are
stored in a separate private file that is **also excluded from backup**. (Earlier
versions kept some of this in standard app preferences, which *do* get backed up;
the app now migrates that data into the excluded storage on launch and removes
the old copies.) Only non-health settings — your chosen voice, announcement
interval, units, and the Apple Health toggle below — remain in ordinary,
backed-up preferences.

Code: `lib/services/health_profile_store.dart`,
`lib/providers/workout_provider.dart`.

## 5. Saving to Apple Health is optional

By default, each finished workout is saved to Apple Health (duration, activity
type, heart rate, calories) so it counts toward your Activity rings. Once a
workout is in Apple Health, it follows **your own** iCloud Health sync settings —
so it can reach your other Apple devices, but only within your private Apple
account, never to halfmarble.

If you'd rather keep workouts entirely on this device, turn off
**Preferences → Apple Health → Save workouts to Apple Health**. With it off, the
workout is discarded and never written to Apple Health.

Code: `ios/Runner/WorkoutManager.swift`, `ios/Runner/AppDelegate.swift`,
`lib/providers/workout_provider.dart`.

## 6. No health values in release logs

During development the app could print heart-rate values to the device log. In
shipped (release) builds, those log statements are compiled out entirely, so no
health values are written to the system log.

Code: `lib/providers/workout_provider.dart`.

## 7. No silent sharing or system-integration leaks

The app does not use the clipboard, Siri/Spotlight donations, Handoff, App Groups,
or home-screen widgets — none of the usual paths that can *quietly* move data off
the app or onto other devices. It uses the share sheet in exactly one place: the
**Export My Data** button you tap yourself (section 9). It is never invoked
automatically.

## 8. The spoken readout is audible by design

SteadyHeartBeat's purpose is to announce your heart rate aloud through your
AirPods. If your audio is routed elsewhere (CarPlay, AirPlay, the phone speaker),
the readout plays there instead. That's inherent to the feature — noted here for
completeness.

## 9. Exporting your own data is your choice

Your data belongs to you, so the app lets you take it with you.
**Preferences → Your Data → Export My Data** assembles everything stored on the
device — your workout sessions and your health profile — into a single plaintext
JSON file and hands it to the iOS share sheet, so you can save it to Files,
AirDrop it, or send it wherever you like.

This is the one place the app deliberately moves data *out* of its protected
storage, and only ever when you tap the button. Two things worth knowing:

- **The file is not encrypted.** It's a readable copy of your own data, meant for
  you to use. Once you save it outside the app it's no longer under the app's
  protection — it follows wherever you put it and your own device/cloud settings,
  so keep it somewhere you trust. (Why not encrypt it? Handing you a locked copy
  of your own data would either ship you the key too, or risk locking you out of
  your own data if you lost a passphrase. Portability standards hand over readable
  files for this reason.)
- **It does not upload anywhere.** Export only opens the share sheet; the app still
  makes no network requests of its own. Where the copy goes next is entirely your
  choice.

The companion **Delete All Data** button on the same screen permanently erases your
workout history and health profile from the device (your app settings — voice,
units, intervals — are kept).

Code: `lib/services/export_service.dart`,
`lib/services/session_storage_service.dart`,
`lib/services/health_profile_store.dart`, `lib/providers/workout_provider.dart`,
`lib/screens/preferences_screen.dart`.

---

## What we can't control

A few things sit outside the app by design, and depend on choices you make at the
iOS level:

- **Backups made before this version.** Excluding storage from backup stops
  *future* backups from including it. Anything already captured in an older
  backup stays there until that backup is replaced.
- **Apple Health sync.** If you leave the Apple Health toggle on (section 5),
  saved workouts sync according to your iCloud Health settings — your choice.
- **System crash diagnostics.** If you have iOS "Share With App Developers"
  turned on, a crash report could in principle include data that was in memory at
  the time. This is standard iOS behavior that you control in Settings.

## How this is verified

These guarantees are backed by automated tests, so they don't quietly regress:

- `test/data_privacy_test.dart` — health data is never written to backed-up
  preferences; the migration never loses your data; the Apple Health toggle is
  honored; and the dependency allowlist blocks new libraries.
- `test/storage_backup_test.dart` — the private stores read and write correctly,
  the backup-exclusion flag is actually applied to each storage folder, and the
  one-time migration copies your data into the excluded store before removing the
  old copies.
- `test/data_export_test.dart` — the export bundle contains your sessions and
  health profile and nothing else; "Delete All Data" removes every stored session
  and the health profile while keeping non-health app settings.

Two pieces are verifiable only in a full iOS build rather than a unit test: the
native code that discards a workout when the Apple Health toggle is off, and the
removal of debug logging from release builds.

---

*Questions? privacy@halfmarble.com. See also the
[privacy policy](https://halfmarble.com/steadyheartbeat/privacy.html).*
