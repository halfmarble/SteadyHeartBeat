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

class PreferencesScreen extends StatelessWidget {
  const PreferencesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preferences'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.pop(context),
          child: Semantics(
            button: true,
            label: 'Back',
            child: const Icon(CupertinoIcons.back, color: kAccent),
          ),
        ),
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
              subtitle: 'Age, sex, weight, conditions & resting metrics',
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
              subtitle: 'Danger zone & background alerts',
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
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.pop(context),
          child: Semantics(
            button: true,
            label: 'Back',
            child: const Icon(CupertinoIcons.back, color: kAccent),
          ),
        ),
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
/// danger threshold, VO₂ grading, and the climbing-energy estimate.
class _BodyScreen extends StatelessWidget {
  const _BodyScreen();
  @override
  Widget build(BuildContext context) {
    return _PrefSubScreen(
      title: 'You & your body',
      children: (provider) => [
        const Text(
          'These personalize your heart-rate zones, the danger threshold, VO₂ '
          'grading, and the climbing-energy estimate.',
          style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        const SizedBox(height: 24),
        _SectionHeader(title: 'AGE & SEX'),
        const SizedBox(height: 8),
        const Text(
          'Age sets your estimated max heart rate (208 − 0.7 × age), which drives '
          'your zones and the danger threshold. Sex grades VO₂ max against age- '
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
        _SectionHeader(title: 'HEALTH CONDITIONS'),
        const SizedBox(height: 8),
        _HealthConditionsSection(provider: provider),
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

/// "Alerts" — the danger-zone threshold and background-notification behavior.
class _AlertsScreen extends StatelessWidget {
  const _AlertsScreen();
  @override
  Widget build(BuildContext context) {
    return _PrefSubScreen(
      title: 'Alerts',
      children: (provider) => [
        _SectionHeader(title: 'DANGER ZONE'),
        const SizedBox(height: 8),
        const Text(
          'We alert you when your heart rate gets dangerously high. The threshold '
          'is 90% of your max heart rate, calculated from your age (set under You '
          '& your body).',
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
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.pop(context),
          child: Semantics(
            button: true,
            label: 'Back',
            child: const Icon(CupertinoIcons.back, color: kAccent),
          ),
        ),
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

class _WelcomeSection extends StatelessWidget {
  const _WelcomeSection({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Speak a welcome at launch',
                    style: TextStyle(color: kTextBright, fontSize: kFontLG),
                  ),
                ),
                CupertinoSwitch(
                  value: provider.welcomeEnabled,
                  activeTrackColor: kAccent,
                  onChanged: provider.setWelcomeEnabled,
                ),
              ],
            ),
          ),
          const Divider(color: kStopButton, height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              'When you open the app, it greets you in your chosen voice and '
              'reminds you to put in your AirPods.',
              style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Toggles whether finished workouts are written to Apple Health. Mirrors the
/// [_WelcomeSection] layout: a switch row over an explanatory caption.
class _AppleHealthSection extends StatelessWidget {
  const _AppleHealthSection({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Save workouts to Apple Health',
                    style: TextStyle(color: kTextBright, fontSize: kFontLG),
                  ),
                ),
                CupertinoSwitch(
                  value: provider.saveToHealth,
                  activeTrackColor: kAccent,
                  onChanged: provider.setSaveToHealth,
                ),
              ],
            ),
          ),
          const Divider(color: kStopButton, height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              'On: each finished workout is saved to Apple Health, so it counts '
              'toward your Activity rings. Health then follows your iCloud sync '
              'settings, so it may reach your other Apple devices.\n\n'
              'Off: the workout is kept only inside SteadyHeartBeat and never '
              'leaves this iPhone. Heart rate still works the same during the '
              'session — only the saved record changes.',
              style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// The single row on the main Preferences screen that opens
/// [VoicePreferencesScreen]. Shows the currently-selected voice as a hint.
class _VoicePrefsEntry extends StatelessWidget {
  const _VoicePrefsEntry({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final voice = provider.voiceName ?? 'Automatic';
    return Semantics(
      button: true,
      label: 'Voice and announcements. Voice: $voice. Opens speech settings.',
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VoicePreferencesScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ExcludeSemantics(
            child: Row(
              children: [
                const Icon(CupertinoIcons.waveform, size: kIconXS, color: kAccent),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Voice, interval & change alerts',
                    style: TextStyle(color: kTextBright, fontSize: kFontLG),
                  ),
                ),
                Text(voice,
                    style: const TextStyle(color: kTextSubtle, fontSize: kFontBase)),
                const SizedBox(width: 6),
                const Icon(CupertinoIcons.chevron_right, size: kIconXS, color: kTextLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: kTextLabel,
        fontSize: kFontBase,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _UnitsSelector extends StatelessWidget {
  const _UnitsSelector({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final imperial = provider.useImperial;
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _buildOption('Metric', 'm / km', false, imperial, isFirst: true),
          _buildOption('Imperial', 'ft / mi', true, imperial, isFirst: false),
        ],
      ),
    );
  }

  Widget _buildOption(String label, String sub, bool value, bool current, {required bool isFirst}) {
    final selected = current == value;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label units${selected ? ", selected" : ""}',
        child: GestureDetector(
          onTap: () => provider.setUseImperial(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? kAccent : Colors.transparent,
              borderRadius: BorderRadius.horizontal(
                left:  isFirst  ? const Radius.circular(12) : Radius.zero,
                right: !isFirst ? const Radius.circular(12) : Radius.zero,
              ),
            ),
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: selected ? Colors.white : kTextLabel,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          fontSize: kFontLG)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: TextStyle(
                          color: selected ? Colors.white70 : kTextDim,
                          fontSize: kFontCaption)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceSelector extends StatelessWidget {
  const _VoiceSelector({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final name = provider.voiceName ?? 'Automatic (best available)';
    return Semantics(
      button: true,
      label: 'Announce voice, currently $name. Opens the voice picker.',
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VoiceScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ExcludeSemantics(
            child: Row(
              children: [
                const Icon(CupertinoIcons.waveform, size: kIconXS, color: kAccent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(color: kTextBright, fontSize: kFontLG),
                  ),
                ),
                const Icon(CupertinoIcons.chevron_right, size: kIconXS, color: kTextLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IntervalSelector extends StatelessWidget {
  const _IntervalSelector({required this.provider});
  final WorkoutProvider provider;

  static const _options = [
    (seconds: 0,  label: '0'),
    (seconds: 2,  label: '2s'),
    (seconds: 5,  label: '5s'),
    (seconds: 15, label: '15s'),
    (seconds: 30, label: '30s'),
    (seconds: 60, label: '1 min'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: _options.asMap().entries.map((entry) {
          final idx = entry.key;
          final opt = entry.value;
          final selected = provider.announceIntervalSeconds == opt.seconds;
          return Expanded(
            child: Semantics(
              button: true,
              selected: selected,
              label: '${opt.seconds == 0 ? "continuous" : opt.label} announce interval${selected ? ", selected" : ""}',
              child: GestureDetector(
                onTap: () => provider.setAnnounceInterval(opt.seconds),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: selected ? kAccent : Colors.transparent,
                    borderRadius: BorderRadius.horizontal(
                      left: idx == 0 ? const Radius.circular(12) : Radius.zero,
                      right: idx == _options.length - 1 ? const Radius.circular(12) : Radius.zero,
                    ),
                  ),
                  child: ExcludeSemantics(
                    child: Text(
                      opt.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: selected ? Colors.white : kTextLabel,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _DeltaSection extends StatelessWidget {
  const _DeltaSection({required this.provider});
  final WorkoutProvider provider;

  static const _thresholds = [
    (bpm: 3, label: '±3'),
    (bpm: 5, label: '±5'),
    (bpm: 8, label: '±8'),
    (bpm: 10, label: '±10'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Announce on change',
                  style: TextStyle(color: kTextBright, fontSize: kFontLG),
                ),
                CupertinoSwitch(
                  value: provider.deltaAnnounceEnabled,
                  activeTrackColor: kAccent,
                  onChanged: provider.setDeltaAnnounceEnabled,
                ),
              ],
            ),
          ),
          if (provider.deltaAnnounceEnabled) ...[
            const Divider(color: kStopButton, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Threshold',
                    style: TextStyle(color: kTextLabel, fontSize: kFontBase, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: kSurfaceDark,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: _thresholds.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final opt = entry.value;
                        final selected = provider.deltaThreshold == opt.bpm;
                        return Expanded(
                          child: Semantics(
                            button: true,
                            selected: selected,
                            label: '${opt.label} BPM change threshold${selected ? ", selected" : ""}',
                            child: GestureDetector(
                              onTap: () => provider.setDeltaThreshold(opt.bpm),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: selected ? kAccent : Colors.transparent,
                                  borderRadius: BorderRadius.horizontal(
                                    left: idx == 0 ? const Radius.circular(8) : Radius.zero,
                                    right: idx == _thresholds.length - 1 ? const Radius.circular(8) : Radius.zero,
                                  ),
                                ),
                                child: ExcludeSemantics(
                                  child: Text(
                                    opt.label,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: selected ? Colors.white : kTextLabel,
                                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HealthConditionsSection extends StatelessWidget {
  const _HealthConditionsSection({required this.provider});
  final WorkoutProvider provider;

  static const _conditions = [
    (key: 'cardiovascular', label: 'Cardiovascular condition'),
    (key: 'hypertension',   label: 'Hypertension'),
    (key: 'diabetes',       label: 'Diabetes'),
    (key: 'parkinsons',     label: "Parkinson's disease"),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Do you have any of the following? This helps us apply '
          'appropriate heart rate defaults for your workouts. '
          'Stays on this iPhone — nothing leaves it without your explicit permission.',
          style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: _conditions.asMap().entries.map((entry) {
              final idx  = entry.key;
              final cond = entry.value;
              final selected = provider.healthConditions.contains(cond.key);
              final isLast   = idx == _conditions.length - 1;
              return Column(
                children: [
                  Semantics(
                    toggled: selected,
                    label: '${cond.label}${selected ? ", selected" : ""}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          ExcludeSemantics(
                            child: Text(
                              cond.label,
                              style: const TextStyle(color: kTextBright, fontSize: kFontLG),
                            ),
                          ),
                          CupertinoSwitch(
                            value: selected,
                            activeTrackColor: kAccent,
                            onChanged: (v) {
                              final next = Set<String>.from(provider.healthConditions);
                              if (v) { next.add(cond.key); } else { next.remove(cond.key); }
                              provider.setHealthConditions(next);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!isLast) const Divider(color: kStopButton, height: 1),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _HealthAuthSection extends StatelessWidget {
  const _HealthAuthSection({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final error = provider.healthFetchError;
    // HealthKit is already the active source for age — show the button as
    // disabled with an "Authorized" label so the user can see that HK is in
    // use without an action to take.
    final authorized = provider.healthAge != null && provider.manualAge == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kErrorBorder),
            ),
            child: Text(
              error,
              style: const TextStyle(color: kAccent, fontSize: kFontBase, height: 1.4),
            ),
          ),
          const SizedBox(height: 10),
        ],
        SizedBox(
          height: 44,
          child: provider.healthFetchPending
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  ),
                )
              : FilledButton(
                  onPressed: authorized ? null : () => provider.requestHealthZones(),
                  style: FilledButton.styleFrom(
                    backgroundColor: kSurface,
                    foregroundColor: kAccent,
                    side: BorderSide(color: authorized ? kTextDim : kAccent),
                    disabledBackgroundColor: kSurface,
                    disabledForegroundColor: kTextDim,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(
                    authorized
                        ? 'Health Access Authorized'
                        : (error != null ? 'Try Again' : 'Authorize Health Access'),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Lets the owner exercise their data rights: export a complete, plaintext copy
/// off-device via the system share sheet, or erase everything stored on the
/// device. The export is the one place the app deliberately moves data out of
/// its protected storage, and only on an explicit tap — see DATA_PORTABILITY.md.
class _YourDataSection extends StatefulWidget {
  const _YourDataSection({required this.provider});
  final WorkoutProvider provider;

  @override
  State<_YourDataSection> createState() => _YourDataSectionState();
}

class _YourDataSectionState extends State<_YourDataSection> {
  bool _exporting = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    // Refresh on open so the Export / Delete-All buttons reflect sessions added
    // or removed elsewhere (e.g. the Sessions screen) since launch.
    widget.provider.refreshSessionCount();
  }

  Future<void> _export() async {
    // Let the owner choose a plaintext copy (usable anywhere) or an anonymized
    // research donation. See DATA_PORTABILITY.md.
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Export My Data'),
        message: const Text(
            'A copy of your sessions and health profile, readable anywhere. Or '
            'contribute an anonymized copy to research.'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'plain'),
            child: const Text('Export a Copy'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'donate'),
            child: const Text('Anonymize for Research…'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final origin = _shareOrigin();

    if (choice == 'donate') {
      await _donate(origin);
      return;
    }

    setState(() => _exporting = true);
    final err = await ExportService.exportToShareSheet(origin: origin);
    if (!mounted) return;
    setState(() => _exporting = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not prepare your data for export. Please try again.'),
      ));
    }
  }

  /// A non-zero share-sheet anchor rect for this section. share_plus/iOS reject a
  /// zero-size sharePositionOrigin even on iPhone, so anchor to the real on-screen
  /// rect (fallback: a 1×1 rect at screen centre).
  Rect _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.of(context).size;
    return Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2), width: 1, height: 1);
  }

  /// Builds and shares an anonymized, OpenBioenergyGauge-shaped research donation
  /// after an explicit consent step. Nothing is uploaded — the user chooses where
  /// the file goes. See [DonationService].
  Future<void> _donate(Rect origin) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Contribute anonymized data'),
        content: const Text(
          '\nThis creates a file with your workout heart-rate timelines only — no '
          'name, age, sex, or conditions. Each session gets a random ID and its '
          'clock is shifted by a random amount (±7 days), so it can\'t be traced '
          'to you or to a daily schedule. Nothing is uploaded; you choose where to '
          'send the file.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create File'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _exporting = true);
    final err = await DonationService.shareDonation(origin: origin);
    if (!mounted) return;
    setState(() => _exporting = false);
    if (err == 'empty') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No finished workouts to contribute yet.'),
      ));
    } else if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not prepare the anonymized file. Please try again.'),
      ));
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('Delete all data?'),
        content: const Text(
          'This permanently removes your workout history and health profile '
          '(age, sex, conditions, and metrics) from this device. Your app '
          'settings are kept. This cannot be undone.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _deleting = true);
    final removed = await widget.provider.clearAllData();
    if (!mounted) return;
    setState(() => _deleting = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(removed == 1
          ? 'Deleted 1 session and your health profile.'
          : 'Deleted $removed sessions and your health profile.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final busy = _exporting || _deleting;
    final hasSessions = widget.provider.sessionCount > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Your data is yours. Export a complete, readable copy to keep or '
          'share — it leaves the app\'s protected storage. Or erase everything '
          'stored on this device.',
          style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        if (!hasSessions) ...[
          const SizedBox(height: 8),
          const Text(
            'No workouts recorded yet — finish a session to enable export and delete.',
            style: TextStyle(color: kTextDim, fontSize: kFontCaption, height: 1.3),
          ),
        ],
        const SizedBox(height: 14),
        SizedBox(
          height: 44,
          child: FilledButton(
            onPressed: (busy || !hasSessions) ? null : _export,
            style: FilledButton.styleFrom(
              backgroundColor: kSurface,
              foregroundColor: kAccent,
              side: BorderSide(color: (busy || !hasSessions) ? kTextDim : kAccent),
              disabledBackgroundColor: kSurface,
              disabledForegroundColor: kTextDim,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  )
                : const Text('Export My Data'),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 44,
          child: FilledButton(
            onPressed: (busy || !hasSessions) ? null : _confirmDelete,
            style: FilledButton.styleFrom(
              backgroundColor: kSurface,
              foregroundColor: kAccent,
              side: BorderSide(color: (busy || !hasSessions) ? kTextDim : kAccent),
              disabledBackgroundColor: kSurface,
              disabledForegroundColor: kTextDim,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: _deleting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  )
                : const Text('Delete All Data'),
          ),
        ),
        const SizedBox(height: 10),
        // Deliberately NOT gated on hasSessions — recovering lost sessions
        // from Apple Health is most needed when the local list is empty.
        SizedBox(
          height: 44,
          child: FilledButton(
            onPressed: busy
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ImportHealthScreen()),
                    ).then((_) => widget.provider.refreshSessionCount()),
            style: FilledButton.styleFrom(
              backgroundColor: kSurface,
              foregroundColor: kAccent,
              side: BorderSide(color: busy ? kTextDim : kAccent),
              disabledBackgroundColor: kSurface,
              disabledForegroundColor: kTextDim,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Import from Apple Health'),
          ),
        ),
      ],
    );
  }
}

class _NotificationsSection extends StatefulWidget {
  const _NotificationsSection();

  @override
  State<_NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<_NotificationsSection> with WidgetsBindingObserver {
  String _status = 'unknown';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Refresh on resume — user may have toggled the permission in Settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = await WorkoutService().getNotificationStatus();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _request() async {
    setState(() => _busy = true);
    await WorkoutService().requestNotificationPermission();
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openSettings() async {
    await launchUrl(Uri.parse('app-settings:'));
  }

  @override
  Widget build(BuildContext context) {
    final explanation = switch (_status) {
      'authorized' || 'provisional' || 'ephemeral' =>
        'Enabled. If iOS kills monitoring while the app is in the background, you\'ll get a notification so you know to restart it.',
      'denied' =>
        'Notifications are denied. If iOS kills monitoring in the background you won\'t know, and you\'ll keep exercising thinking it\'s still tracking. Open Settings to re-enable.',
      _ =>
        'iOS may kill background apps to free memory. With this on, you\'ll get a notification if monitoring stops mid-workout so you can restart it instead of silently losing the rest of the session.',
    };

    Widget? action;
    if (_status == 'notDetermined' || _status == 'unknown') {
      action = FilledButton(
        onPressed: _busy ? null : _request,
        style: FilledButton.styleFrom(
          backgroundColor: kSurface,
          foregroundColor: kAccent,
          side: const BorderSide(color: kAccent),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: _busy
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
              )
            : const Text('Enable Notifications'),
      );
    } else if (_status == 'denied') {
      action = FilledButton(
        onPressed: _openSettings,
        style: FilledButton.styleFrom(
          backgroundColor: kSurface,
          foregroundColor: kAccent,
          side: const BorderSide(color: kAccent),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: const Text('Open Settings'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          explanation,
          style: const TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        if (action != null) ...[
          const SizedBox(height: 10),
          SizedBox(height: 44, child: action),
        ],
      ],
    );
  }
}

/// Opens a [CupertinoPicker] in a bottom sheet rather than inline, so the wheel
/// can't capture the Preferences ListView's vertical drags — an inline wheel is a
/// nested vertical scrollable and steals slow page drags. [onSelectedItemChanged]
/// fires live as the wheel spins; the controller is disposed when the sheet closes.
Future<void> _showWheelSheet(
  BuildContext context, {
  required int itemCount,
  required int initialItem,
  required double itemExtent,
  required IndexedWidgetBuilder itemBuilder,
  required ValueChanged<int> onSelectedItemChanged,
}) {
  final controller = FixedExtentScrollController(initialItem: initialItem);
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (ctx) => Container(
      height: 280,
      decoration: const BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done',
                    style: TextStyle(color: kAccent, fontWeight: FontWeight.w600)),
              ),
            ),
            Expanded(
              child: CupertinoPicker(
                scrollController: controller,
                itemExtent: itemExtent,
                backgroundColor: kSurface,
                squeeze: 1.15,
                onSelectedItemChanged: onSelectedItemChanged,
                children:
                    List<Widget>.generate(itemCount, (i) => itemBuilder(ctx, i)),
              ),
            ),
          ],
        ),
      ),
    ),
  ).whenComplete(controller.dispose);
}

/// A tappable preferences row (label + current value + chevron) that opens its
/// wheel in [_showWheelSheet]. Replaces the old inline wheels so the page scrolls
/// cleanly. [footnote] sits inside the card under the row (e.g. the stale hint).
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.label,
    required this.value,
    required this.source,
    required this.onTap,
    this.semanticsLabel,
    this.footnote,
  });
  final String label;
  final String value;
  final String source;
  final VoidCallback onTap;
  final String? semanticsLabel;
  final Widget? footnote;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: semanticsLabel ?? '$label, $value',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label,
                              style: const TextStyle(
                                  color: kTextBright, fontSize: kFontLG)),
                          const SizedBox(height: 2),
                          Text(source,
                              style: const TextStyle(
                                  color: kTextDim, fontSize: kFontCaption)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(value,
                        style:
                            const TextStyle(color: kTextBright, fontSize: kFontLG)),
                    const SizedBox(width: 6),
                    const Icon(CupertinoIcons.chevron_right,
                        color: kTextDim, size: 18),
                  ],
                ),
              ),
            ),
          ),
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: footnote!,
            ),
        ],
      ),
    );
  }
}

class _AgePickerSection extends StatefulWidget {
  const _AgePickerSection({required this.provider});
  final WorkoutProvider provider;

  @override
  State<_AgePickerSection> createState() => _AgePickerSectionState();
}

class _AgePickerSectionState extends State<_AgePickerSection> {
  static const _minAge = 18;
  static const _maxAge = 100;

  Timer? _debounce;

  int get _count => (_maxAge - _minAge + 1) + 1; // +1 for the Auto row

  int _indexFor(int? manual) =>
      manual == null ? 0 : (manual.clamp(_minAge, _maxAge) - _minAge + 1);

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  // Debounced so we don't write to prefs on every wheel tick. "Auto" (index 0)
  // clears the manual override and falls back to Apple Health.
  void _onChanged(int index) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      widget.provider.setManualAge(index == 0 ? null : index - 1 + _minAge);
    });
  }

  String _source() {
    if (widget.provider.manualAge != null) return 'manual';
    if (widget.provider.healthAge != null) return 'Apple Health';
    return 'not set';
  }

  String _value() {
    final p = widget.provider;
    if (p.manualAge != null) return '${p.manualAge}';
    if (p.healthAge != null) return '${p.healthAge}';
    return 'Set';
  }

  void _open() {
    final p = widget.provider;
    final autoAge = p.manualAge == null ? p.healthAge : null;
    final autoText = autoAge != null ? 'Auto ($autoAge)' : 'Auto';
    _showWheelSheet(
      context,
      itemCount: _count,
      initialItem: _indexFor(p.manualAge),
      itemExtent: 32,
      onSelectedItemChanged: _onChanged,
      itemBuilder: (_, i) => Center(
        child: Text(
          i == 0 ? autoText : '${i - 1 + _minAge}',
          style:
              TextStyle(fontSize: 18, color: i == 0 ? kTextMuted : Colors.white),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PickerRow(
      label: 'Your age',
      value: _value(),
      source: _source(),
      semanticsLabel: 'Age override',
      onTap: _open,
    );
  }
}

/// Biological sex picker, shown under the age picker and built from the same
/// CupertinoPicker dial: row 0 is Auto (reads from Apple Health, with the
/// resolved value in brackets, e.g. "Auto (Male)"), then Female / Male. Used to
/// grade VO₂ max against age- and sex-specific norms (see health_norms.dart).
class _SexPickerSection extends StatefulWidget {
  const _SexPickerSection({required this.provider});
  final WorkoutProvider provider;

  @override
  State<_SexPickerSection> createState() => _SexPickerSectionState();
}

class _SexPickerSectionState extends State<_SexPickerSection> {
  // Wheel rows: 0 = Auto, 1 = Female, 2 = Male.
  Timer? _debounce;

  static String _pretty(String s) =>
      s == 'female' ? 'Female' : s == 'male' ? 'Male' : 'Other';

  int _indexFor(String? manual) =>
      manual == 'male' ? 2 : manual == 'female' ? 1 : 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  // Debounced like the age dial. Row 0 (Auto) clears the override and falls back
  // to Apple Health.
  void _onChanged(int index) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      widget.provider
          .setManualSex(index == 0 ? null : (index == 1 ? 'female' : 'male'));
    });
  }

  String _source() {
    if (widget.provider.manualSex != null) return 'manual';
    if (widget.provider.healthSex != null) return 'Apple Health';
    return 'not set';
  }

  String _value() {
    final p = widget.provider;
    if (p.manualSex != null) return _pretty(p.manualSex!);
    if (p.healthSex != null) return _pretty(p.healthSex!);
    return 'Set';
  }

  void _open() {
    final p = widget.provider;
    final autoSex = p.manualSex == null ? p.healthSex : null;
    final autoText = autoSex != null ? 'Auto (${_pretty(autoSex)})' : 'Auto';
    _showWheelSheet(
      context,
      itemCount: 3,
      initialItem: _indexFor(p.manualSex),
      itemExtent: 32,
      onSelectedItemChanged: _onChanged,
      itemBuilder: (_, i) => Center(
        child: Text(
          i == 0 ? autoText : (i == 1 ? 'Female' : 'Male'),
          style:
              TextStyle(fontSize: 18, color: i == 0 ? kTextMuted : Colors.white),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PickerRow(
      label: 'Your sex',
      value: _value(),
      source: _source(),
      semanticsLabel: 'Biological sex override',
      onTap: _open,
    );
  }
}

// ── Resting-metric manual overrides (stale/absent Apple Watch data) ───────────

class _RestingMetricsSection extends StatelessWidget {
  const _RestingMetricsSection({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Apple Health values can go stale — if the Apple Watch isn\'t worn, or if '
          'your fitness data comes from a different watch (Amazfit, Garmin, etc.) that '
          'doesn\'t feed Apple Health. Override any of these manually — pick a value, '
          'or leave it on “Apple Health” to use the live reading. Manual values take '
          'precedence everywhere they\'re shown.',
          style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        const SizedBox(height: 12),
        _MetricOverride(
          label: 'Resting HRV', unit: 'ms', min: 5, max: 200,
          autoValue: provider.recentHrvMs, autoDate: provider.recentHrvDate,
          manualValue: provider.manualHrvMs, onChanged: provider.setManualHrv,
          staleHint: 'From another watch (Amazfit, Garmin…)? Tap to enter it.',
        ),
        const SizedBox(height: 16),
        _MetricOverride(
          label: 'Resting HR', unit: 'bpm', min: 35, max: 120,
          autoValue: provider.recentRestingHrBpm,
          autoDate: provider.recentRestingHrDate,
          manualValue: provider.manualRestingHr,
          onChanged: provider.setManualRestingHr,
          staleHint: 'From another watch (Amazfit, Garmin…)? Tap to enter it.',
        ),
        const SizedBox(height: 16),
        _MetricOverride(
          label: 'VO₂ max', unit: 'ml/kg/min', min: 15, max: 80,
          autoValue: provider.recentVo2MaxMlPerKgMin,
          autoDate: provider.recentVo2MaxDate,
          manualValue: provider.manualVo2Max,
          onChanged: provider.setManualVo2Max,
          staleHint: 'From another watch (Amazfit, Garmin…)? Tap to enter it.',
        ),
        const SizedBox(height: 20),
        const Text(
          'Auto values come from Apple Health. The app reads them at launch — tap '
          'to pull the latest now and use them (this switches any manual override '
          'back to the Apple Health value, where one exists).',
          style: TextStyle(color: kTextSubtle, fontSize: kFontCaption, height: 1.4),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 44,
          width: double.infinity,
          child: provider.healthRefreshPending
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  ),
                )
              : FilledButton.icon(
                  onPressed: () => provider.refreshHealthData(),
                  icon: const Icon(CupertinoIcons.square_arrow_down, size: 18),
                  label: const Text('Read from Apple Health'),
                  style: FilledButton.styleFrom(
                    backgroundColor: kSurface,
                    foregroundColor: kAccent,
                    side: const BorderSide(color: kAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
        ),
        if (provider.healthRefreshError != null) ...[
          const SizedBox(height: 8),
          Text(
            provider.healthRefreshError!,
            style: const TextStyle(color: kAccent, fontSize: kFontCaption, height: 1.3),
          ),
        ],
      ],
    );
  }
}

/// Body-weight override — same Auto/manual wheel as the resting metrics and the
/// age picker, but shown in lb or kg per the unit setting. Stored internally in
/// kg (the elevation energy term, W = m·g·h, needs SI); "Auto" uses Apple Health.
class _WeightSection extends StatelessWidget {
  const _WeightSection({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final imperial = provider.useImperial;
    final factor = imperial ? 2.20462 : 1.0; // kg → display unit
    final unit = imperial ? 'lb' : 'kg';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Used to estimate the energy of climbing — work against gravity '
          '(mass × g × ascent). Leave it on “Apple Health,” or tap to set it manually.',
          style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        const SizedBox(height: 12),
        _MetricOverride(
          label: 'Weight',
          unit: unit,
          min: imperial ? 66 : 30,
          max: imperial ? 440 : 200,
          autoValue:
              provider.autoBodyMassKg == null ? null : provider.autoBodyMassKg! * factor,
          autoDate: provider.autoBodyMassDate,
          manualValue:
              provider.manualWeightKg == null ? null : provider.manualWeightKg! * factor,
          onChanged: (v) => provider.setManualWeight(v == null ? null : v / factor),
        ),
      ],
    );
  }
}

/// One resting-metric row: a tappable value that opens a wheel picker in a
/// sheet; the first wheel item is "Auto" (use Apple Health). Selecting a number
/// sets the manual override; selecting "Auto" clears it.
class _MetricOverride extends StatefulWidget {
  const _MetricOverride({
    required this.label,
    required this.unit,
    required this.min,
    required this.max,
    required this.autoValue,
    required this.autoDate,
    required this.manualValue,
    required this.onChanged,
    this.staleHint,
  });
  final String label, unit;
  final int min, max;
  final double? autoValue;
  final DateTime? autoDate;
  final double? manualValue;
  final ValueChanged<double?> onChanged;
  final String? staleHint; // nudge under the wheel when the Auto value is missing/stale

  @override
  State<_MetricOverride> createState() => _MetricOverrideState();
}

class _MetricOverrideState extends State<_MetricOverride> {
  Timer? _debounce;

  int get _count => (widget.max - widget.min + 1) + 1; // +1 for the Auto row

  int _indexFor(double? manual) => manual == null
      ? 0
      : (manual.round().clamp(widget.min, widget.max) - widget.min + 1);

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  // Debounced so we don't write to prefs on every wheel tick.
  void _onChanged(int index) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      widget.onChanged(index == 0 ? null : (index - 1 + widget.min).toDouble());
    });
  }

  String _source() {
    if (widget.manualValue != null) return 'manual';
    if (widget.autoValue == null) return 'no Apple Health data';
    final d = widget.autoDate;
    final age = d == null ? '' : ' · ${DateTime.now().difference(d).inDays}d old';
    return 'Apple Health$age';
  }

  // True when the Auto value is missing or stale (older than
  // WorkoutProvider.kStaleMetricDays = 30) and there's no manual override — i.e.
  // when we should nudge the user to enter it themselves (e.g. from another watch).
  bool get _suggestManual {
    if (widget.manualValue != null) return false;
    if (widget.autoValue == null) return true;
    final d = widget.autoDate;
    return d != null && DateTime.now().difference(d).inDays > 30;
  }

  String _value() {
    if (widget.manualValue != null) {
      return '${widget.manualValue!.round()} ${widget.unit}';
    }
    if (widget.autoValue != null) {
      return '${widget.autoValue!.round()} ${widget.unit}';
    }
    return 'Set';
  }

  void _open() {
    _showWheelSheet(
      context,
      itemCount: _count,
      initialItem: _indexFor(widget.manualValue),
      itemExtent: 32,
      onSelectedItemChanged: _onChanged,
      itemBuilder: (_, i) {
        final autoText = widget.autoValue != null
            ? 'Apple Health (${widget.autoValue!.round()})'
            : 'Apple Health (none)';
        return Center(
          child: Text(
            i == 0 ? autoText : '${i - 1 + widget.min} ${widget.unit}',
            style:
                TextStyle(fontSize: 18, color: i == 0 ? kTextMuted : Colors.white),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PickerRow(
      label: widget.label,
      value: _value(),
      source: _source(),
      semanticsLabel: '${widget.label} override',
      onTap: _open,
      footnote: (_suggestManual && widget.staleHint != null)
          ? Text(widget.staleHint!,
              style: const TextStyle(
                  color: kZone3, fontSize: kFontCaption, height: 1.3))
          : null,
    );
  }
}

class _AboutSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Build number from kBuildNumber (auto-written by the Xcode build phase, the
    // same source as the home header badge — so they can't disagree). "+" marks
    // an Plus build (module compiled in), shown in both places or neither.
    final plus = context.read<WorkoutProvider>().plus.available;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          'halfmarble',
          style:
              TextStyle(color: kTextFaint, fontSize: kFontMD, letterSpacing: 0.5),
        ),
        const SizedBox(height: 4),
        Text(
          'SteadyHeartBeat 1.0.0 ($kBuildNumber${plus ? '+' : ''})',
          style: const TextStyle(color: kTextFaint, fontSize: kFontBase),
        ),
      ],
    );
  }
}

class _ResearchNote extends StatelessWidget {
  const _ResearchNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(CupertinoIcons.lab_flask, color: kTextFaint, size: 12),
              SizedBox(width: 6),
              Text(
                'CONTRIBUTING TO RESEARCH',
                style: TextStyle(
                  color: kTextDim,
                  fontSize: kFontSM,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'halfmarble is working with research institutions to let you '
            'optionally contribute anonymized workout data to Parkinson\'s '
            'disease research. If we ever offer this opt-in, it will be a '
            'specific study under IRB approval with openly published findings, '
            'and only with your explicit consent — your data will never be '
            'sold.',
            style: TextStyle(
              color: kTextDim,
              fontSize: kFontBase,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 10),
          Semantics(
            link: true,
            label: 'Visit halfmarble glass box data policy page',
            child: GestureDetector(
            onTap: () => launchUrl(
              Uri.parse('https://halfmarble.com/glass-box/data.html'),
              mode: LaunchMode.externalApplication,
            ),
            child: RichText(
              text: const TextSpan(
                style: TextStyle(fontSize: kFontCaption, height: 1.4, fontStyle: FontStyle.italic),
                children: [
                  TextSpan(
                    text: 'Learn more at ',
                    style: TextStyle(color: kTextFaint),
                  ),
                  TextSpan(
                    text: 'halfmarble.com/glass-box/data.html',
                    style: TextStyle(
                      color: kTextLabel,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
          ),
          ),  // closes Semantics(link:)
        ],
      ),
    );
  }
}
