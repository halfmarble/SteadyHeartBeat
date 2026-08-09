import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Core-side surface of the Plus paid module.
///
/// The core app talks to Plus exclusively through this interface. The
/// implementation is selected by `createPlusFeatures` in plus_binding.dart —
/// the one file that differs between the private repo (real module under
/// lib/plus/) and the public export (which binds [NoPlusFeatures]). Core code
/// must never import lib/plus/ directly: the public tree has to compile
/// without it.
abstract class PlusFeatures {
  /// Whether the paid module is compiled into this build at all.
  bool get available;

  /// Whether the user owns the Plus unlock (StoreKit entitlement).
  bool get unlocked;

  /// Whether the trends/research surface (daily metric charts, sleep, naps,
  /// recovery) is visible in this build. Owner-only by design: trends is
  /// halfmarble's research instrument (the OpenBioenergyGauge rehearsal), not
  /// part of the sellable Plus scope, so it never keys off the StoreKit
  /// entitlement.
  bool get trendsVisible;

  /// Pushes the current StoreKit entitlement into the module. Called by the
  /// provider whenever the `steadyheartbeat/entitlements` stream changes (and
  /// once at startup). The module updates [unlocked] and notifies listeners.
  /// Inert in the free core.
  void setUnlocked(bool owned);

  /// Prefs round-trip for the module's persisted settings. Called from the
  /// provider's _loadPrefs / savePrefs.
  void loadPrefs(SharedPreferences prefs);
  Future<void> savePrefs(SharedPreferences prefs);

  /// A workout is starting: reset live state and push the module's native
  /// config BEFORE startWorkout (same ordering contract as _pushBoxingConfig).
  void onWorkoutStart();

  /// Ingest a native 'round' status event (the provider notifies listeners
  /// right after this returns).
  void onRoundEvent(Map<String, dynamic> data);

  /// True while a module-driven phase should replace the boxing round banner.
  bool get gateActive;

  /// The module's Preferences block (its own header and trailing spacing
  /// included), or null when the module is absent or locked.
  Widget? preferencesSection(BuildContext context);

  /// Replacement for the boxing round banner during a module-driven phase,
  /// or null to render the standard banner.
  Widget? roundBanner(BuildContext context, String phase);

  /// Opens the daily-trends view for [metricKey]. A no-op unless
  /// [trendsVisible] — callers hide the affordance in customer builds, and the
  /// method guards anyway. Called from the home readiness snapshot when the
  /// user taps a metric value (a distinct affordance from the ⓘ explainer on
  /// the metric's label).
  void openTrends(BuildContext context, String metricKey);
}

/// The free-core binding: no paid module compiled in. Every member is inert,
/// so the app behaves exactly like the pre-Plus free core.
class NoPlusFeatures implements PlusFeatures {
  @override
  bool get available => false;
  @override
  bool get unlocked => false;
  @override
  bool get trendsVisible => false;
  @override
  void setUnlocked(bool owned) {}
  @override
  void loadPrefs(SharedPreferences prefs) {}
  @override
  Future<void> savePrefs(SharedPreferences prefs) async {}
  @override
  void onWorkoutStart() {}
  @override
  void onRoundEvent(Map<String, dynamic> data) {}
  @override
  bool get gateActive => false;
  @override
  Widget? preferencesSection(BuildContext context) => null;
  @override
  Widget? roundBanner(BuildContext context, String phase) => null;
  @override
  void openTrends(BuildContext context, String metricKey) {}
}
