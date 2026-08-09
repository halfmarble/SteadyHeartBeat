import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../build_info.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/workout_provider.dart';
import '../services/workout_service.dart';
import '../services/export_service.dart';
import '../services/donation_service.dart';
import '../constants.dart';
import 'voice_screen.dart';
import 'import_health_screen.dart';
import '../widgets/app_chrome.dart';

part 'preferences_sections.dart';
part 'preferences_data.dart';
part 'preferences_profile.dart';

class PreferencesScreen extends StatelessWidget {
  const PreferencesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preferences'),
        leading: backButton(context),
      ),
      body: Consumer<WorkoutProvider>(
        builder: (context, provider, _) => ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          children: [
            _VoicePrefsEntry(provider: provider),
            const SizedBox(height: 12),
            _NavRow(
              icon: CupertinoIcons.person,
              title: 'You & your body',
              subtitle: 'Age, sex, weight & resting metrics',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _BodyScreen())),
            ),
            const SizedBox(height: 12),
            _NavRow(
              icon: CupertinoIcons.heart,
              title: 'Apple Health',
              subtitle: 'Access, and saving workouts to Health',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _AppleHealthScreen())),
            ),
            const SizedBox(height: 12),
            _NavRow(
              icon: CupertinoIcons.bell,
              title: 'Alerts',
              subtitle: 'Ceiling & background alerts',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _AlertsScreen())),
            ),
            const SizedBox(height: 12),
            // Plus module — absent in the free core / while the upgrade is locked.
            if (provider.plus.preferencesSection(context) != null) ...[
              _NavRow(
                icon: CupertinoIcons.timer,
                title: 'HR-gated protocols (Plus)',
                subtitle: 'Warm-up, recovery-gated rest & cool-down',
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const _GateProtocolsScreen())),
              ),
              const SizedBox(height: 12),
            ],
            _NavRow(
              icon: CupertinoIcons.lock_shield,
              title: 'Your data',
              subtitle: 'Export, delete, or donate to research',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _DataScreen())),
            ),
            const SizedBox(height: 12),
            // Tactile tick when scrubbing a chart — the workout/session HR chart
            // (every build) and the Plus trend charts.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.vibration, size: kIconXS, color: kAccent),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Chart haptics',
                            style: TextStyle(
                                color: kTextBright, fontSize: kFontLG)),
                        SizedBox(height: 2),
                        Text('Tactile tick when scrubbing charts',
                            style: TextStyle(
                                color: kTextSubtle, fontSize: kFontBase)),
                      ],
                    ),
                  ),
                  CupertinoSwitch(
                    value: provider.chartHaptics,
                    activeTrackColor: kAccent,
                    onChanged: (v) {
                      provider.setChartHaptics(v);
                      // Fire a tap when enabling — confirms it's on, and doubles
                      // as a device-haptics probe.
                      if (v) HapticFeedback.lightImpact();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            _SectionHeader(title: 'UNITS'),
            const SizedBox(height: 8),
            _UnitsSelector(provider: provider),
            const SizedBox(height: 48),
            _AboutSection(),
            const SizedBox(height: 32),
            const _ResearchNote(),
          ],
        ),
      ),
    );
  }
}

/// A tappable category row on the main Preferences screen that pushes a focused
/// sub-screen — keeps the top level short instead of one long, busy scroll.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(icon, size: kIconXS, color: kAccent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: kTextBright, fontSize: kFontLG)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!,
                            style: const TextStyle(
                                color: kTextSubtle,
                                fontSize: kFontCaption,
                                height: 1.3)),
                      ],
                    ],
                  ),
                ),
                const Icon(CupertinoIcons.chevron_right,
                    size: kIconXS, color: kTextLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared scaffold for the Preferences sub-screens: an app bar with a back
/// button over a padded [ListView] driven by the live [WorkoutProvider].
class _PrefSubScreen extends StatelessWidget {
  const _PrefSubScreen({required this.title, required this.children});
  final String title;
  final List<Widget> Function(WorkoutProvider provider) children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: backButton(context),
      ),
      body: Consumer<WorkoutProvider>(
        builder: (context, provider, _) => ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          children: children(provider),
        ),
      ),
    );
  }
}

/// "You & your body" — the physiological profile that personalizes zones, the
/// ceiling alert, VO₂ grading, and the climbing-energy estimate.
class _BodyScreen extends StatelessWidget {
  const _BodyScreen();
  @override
  Widget build(BuildContext context) {
    return _PrefSubScreen(
      title: 'You & your body',
      children: (provider) => [
        const Text(
          'These personalize your heart-rate zones, the ceiling alert, VO₂ '
          'grading, and the climbing-energy estimate.',
          style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        const SizedBox(height: 24),
        _SectionHeader(title: 'AGE & SEX'),
        const SizedBox(height: 8),
        const Text(
          'Age sets your estimated max heart rate (208 − 0.7 × age), which drives '
          'your zones and the ceiling alert. Sex grades VO₂ max against age- '
          'and sex-specific norms.',
          style: TextStyle(color: kTextSubtle, fontSize: kFontCaption, height: 1.4),
        ),
        const SizedBox(height: 12),
        _AgePickerSection(provider: provider),
        const SizedBox(height: 16),
        _SexPickerSection(provider: provider),
        const SizedBox(height: 32),
        _SectionHeader(title: 'WEIGHT'),
        const SizedBox(height: 8),
        _WeightSection(provider: provider),
        const SizedBox(height: 32),
        _SectionHeader(title: 'RESTING METRICS'),
        const SizedBox(height: 8),
        _RestingMetricsSection(provider: provider),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// "Apple Health" — the HealthKit integration: permission and saving workouts.
class _AppleHealthScreen extends StatelessWidget {
  const _AppleHealthScreen();
  @override
  Widget build(BuildContext context) {
    return _PrefSubScreen(
      title: 'Apple Health',
      children: (provider) => [
        _HealthAuthSection(provider: provider),
        const SizedBox(height: 32),
        _SectionHeader(title: 'SAVE WORKOUTS'),
        const SizedBox(height: 12),
        _AppleHealthSection(provider: provider),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// "Alerts" — the ceiling-alert threshold and background-notification behavior.
class _AlertsScreen extends StatelessWidget {
  const _AlertsScreen();
  @override
  Widget build(BuildContext context) {
    return _PrefSubScreen(
      title: 'Alerts',
      children: (provider) => [
        _SectionHeader(title: 'CEILING ALERT'),
        const SizedBox(height: 8),
        const Text(
          'We alert you when your heart rate nears your estimated ceiling. The '
          'threshold is 90% of your estimated max heart rate, calculated from '
          'your age (set under You & your body) — a fitness-intensity guide, not '
          'a personal medical limit.',
          style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        const SizedBox(height: 32),
        _SectionHeader(title: 'BACKGROUND ALERTS'),
        const SizedBox(height: 8),
        const _NotificationsSection(),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// "Your data" — export, delete, and research-donation controls.
class _DataScreen extends StatelessWidget {
  const _DataScreen();
  @override
  Widget build(BuildContext context) {
    return _PrefSubScreen(
      title: 'Your data',
      children: (provider) => [
        _YourDataSection(provider: provider),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// "HR-gated protocols (Plus)" — the paid module's gate configuration; reached
/// only when the upgrade is unlocked (the nav row is hidden otherwise).
class _GateProtocolsScreen extends StatelessWidget {
  const _GateProtocolsScreen();
  @override
  Widget build(BuildContext context) {
    return _PrefSubScreen(
      title: 'HR-gated protocols',
      children: (provider) =>
          [provider.plus.preferencesSection(context) ?? const SizedBox.shrink()],
    );
  }
}

/// Standalone page gathering every speech-related setting: the voice picker,
/// the announce interval, and announce-on-change. Reached from the main
/// Preferences screen's "Voice & announcements" entry.
class VoicePreferencesScreen extends StatelessWidget {
  const VoicePreferencesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice & announcements'),
        leading: backButton(context),
      ),
      body: Consumer<WorkoutProvider>(
        builder: (context, provider, _) => ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          children: [
            _SectionHeader(title: 'VOICE'),
            const SizedBox(height: 8),
            _VoiceSelector(provider: provider),
            const SizedBox(height: 32),
            _SectionHeader(title: 'WELCOME MESSAGE'),
            const SizedBox(height: 12),
            _WelcomeSection(provider: provider),
            const SizedBox(height: 32),
            _SectionHeader(title: 'ANNOUNCE INTERVAL'),
            const SizedBox(height: 12),
            _IntervalSelector(provider: provider),
            const SizedBox(height: 32),
            _SectionHeader(title: 'ANNOUNCE ON CHANGE'),
            const SizedBox(height: 12),
            _DeltaSection(provider: provider),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
