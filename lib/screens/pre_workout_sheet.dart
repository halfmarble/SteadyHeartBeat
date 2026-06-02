import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../providers/workout_provider.dart';
import '../constants.dart';

/// Entry point for the Start Workout button. Some workout types get a
/// pre-workout configuration panel (a modal bottom sheet) before monitoring
/// begins; the rest start immediately. The type-specific panel is where
/// per-discipline settings live now — e.g. cycling shows heart-rate zone
/// coaching, boxing will show round-timer settings once those land.
///
/// For types with a panel, [provider.start] is called from inside the sheet's
/// Start button; dismissing the sheet (swipe down) cancels without starting.
Future<void> maybeStartWorkout(
    BuildContext context, WorkoutProvider provider) async {
  switch (provider.selectedWorkoutType) {
    case WorkoutType.cycling:
      await _showZoneSheet(context, provider);
    case WorkoutType.boxing:
      await _showBoxingSheet(context, provider);
    default:
      provider.start();
  }
}

Future<void> _showZoneSheet(
    BuildContext context, WorkoutProvider provider) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBackground,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => _ZoneSheet(provider: provider),
  );
}

Future<void> _showBoxingSheet(
    BuildContext context, WorkoutProvider provider) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBackground,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => _BoxingSheet(provider: provider),
  );
}

String _fmtMMSS(int secs) {
  final m = secs ~/ 60;
  final s = secs % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

class _ZoneSheet extends StatelessWidget {
  const _ZoneSheet({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    // The provider is a ChangeNotifier; AnimatedBuilder rebuilds the sheet when
    // the zone toggle / target zone change, without depending on the modal
    // route inheriting the ChangeNotifierProvider above it.
    return AnimatedBuilder(
      animation: provider,
      builder: (context, _) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.directions_bike, color: kAccent, size: 22),
                  SizedBox(width: 8),
                  Text('Cycling',
                      style: TextStyle(
                          color: kTextBright,
                          fontSize: 20,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 16),
              ZoneCoachingPanel(provider: provider),
              const SizedBox(height: 20),
              Semantics(
                button: true,
                label: 'Start cycling workout',
                child: FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    provider.start();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    minimumSize: const Size(double.infinity, kButtonHeight),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(kButtonRadius)),
                  ),
                  child: const Text('GO!',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Heart-rate zone coaching settings. Lives in the cycling pre-workout sheet
/// (not the global Preferences screen): coaching names your zone in each
/// announcement and, with a target zone set, adds a "push" / "ease off" nudge.
class ZoneCoachingPanel extends StatelessWidget {
  const ZoneCoachingPanel({super.key, required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final hasZones = provider.maxHeartRate != null;
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
                    'Coach my heart-rate zones',
                    style: TextStyle(color: kTextBright, fontSize: kFontLG),
                  ),
                ),
                CupertinoSwitch(
                  value: provider.zoneCoachingEnabled,
                  activeTrackColor: kAccent,
                  onChanged: hasZones ? provider.setZoneCoachingEnabled : null,
                ),
              ],
            ),
          ),
          const Divider(color: kStopButton, height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasZones
                      ? 'Announcements name your zone (“142, zone 4”). Set a target '
                          'zone to also hear “push” or “ease off”.'
                      : 'Add your age in the Danger Zone section (or your date of '
                          'birth in Apple Health) to enable heart-rate zones.',
                  style: const TextStyle(
                      color: kTextSubtle, fontSize: kFontBase, height: 1.4),
                ),
                if (hasZones && provider.zoneCoachingEnabled) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Target zone',
                    style: TextStyle(
                        color: kTextLabel, fontSize: kFontBase, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 8),
                  _TargetZoneSelector(provider: provider),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TargetZoneSelector extends StatelessWidget {
  const _TargetZoneSelector({required this.provider});
  final WorkoutProvider provider;

  static const _opts = [
    (z: 0, label: 'None'),
    (z: 1, label: '1'),
    (z: 2, label: '2'),
    (z: 3, label: '3'),
    (z: 4, label: '4'),
    (z: 5, label: '5'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kSurfaceDark,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: _opts.asMap().entries.map((entry) {
          final idx = entry.key;
          final opt = entry.value;
          final selected = provider.targetZone == opt.z;
          // kZoneColors = [brady, z1..z5]; index == zone number for 1–5.
          final fill = opt.z >= 1 ? kZoneColors[opt.z] : kAccent;
          return Expanded(
            child: Semantics(
              button: true,
              selected: selected,
              label:
                  '${opt.z == 0 ? "no target zone" : "target zone ${opt.z}"}${selected ? ", selected" : ""}',
              child: GestureDetector(
                onTap: () => provider.setTargetZone(opt.z),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: selected ? fill : Colors.transparent,
                    borderRadius: BorderRadius.horizontal(
                      left: idx == 0 ? const Radius.circular(8) : Radius.zero,
                      right: idx == _opts.length - 1
                          ? const Radius.circular(8)
                          : Radius.zero,
                    ),
                  ),
                  child: ExcludeSemantics(
                    child: Center(
                      child: Text(
                        opt.label,
                        style: TextStyle(
                          color: selected ? Colors.white : kTextLabel,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          fontSize: kFontBase,
                        ),
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

// ── Boxing ──────────────────────────────────────────────────────────────────

class _BoxingSheet extends StatelessWidget {
  const _BoxingSheet({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: provider,
      builder: (context, _) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.sports_mma, color: kAccent, size: 22),
                  SizedBox(width: 8),
                  Text('Boxing',
                      style: TextStyle(
                          color: kTextBright,
                          fontSize: 20,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 16),
              BoxingRoundsPanel(provider: provider),
              const SizedBox(height: 20),
              Semantics(
                button: true,
                label: 'Start boxing workout',
                child: FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    provider.start();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    minimumSize: const Size(double.infinity, kButtonHeight),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(kButtonRadius)),
                  ),
                  child: const Text('GO!',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Boxing round-timer settings: a master toggle, then round/rest lengths, round
/// count (∞ = unlimited), and the end-of-round warning cue. Lives in the boxing
/// pre-workout sheet.
class BoxingRoundsPanel extends StatelessWidget {
  const BoxingRoundsPanel({super.key, required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final on = provider.boxingRoundsEnabled;
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
                  child: Text('Round timer',
                      style: TextStyle(color: kTextBright, fontSize: kFontLG)),
                ),
                CupertinoSwitch(
                  value: on,
                  activeTrackColor: kAccent,
                  onChanged: provider.setBoxingRoundsEnabled,
                ),
              ],
            ),
          ),
          if (on) ...[
            const Divider(color: kStopButton, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _PresetChip(
                          label: 'Amateur',
                          detail: '3 × 2:00',
                          onTap: () => provider.applyBoxingPreset(
                              rounds: 3, round: 120, rest: 60),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _PresetChip(
                          label: 'Pro',
                          detail: '12 × 3:00',
                          onTap: () => provider.applyBoxingPreset(
                              rounds: 12, round: 180, rest: 60),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _Stepper(
                    label: 'Round',
                    value: _fmtMMSS(provider.roundSecs),
                    onMinus: () => provider.setRoundSecs(provider.roundSecs - 15),
                    onPlus: () => provider.setRoundSecs(provider.roundSecs + 15),
                  ),
                  _Stepper(
                    label: 'Rest',
                    value: _fmtMMSS(provider.restSecs),
                    onMinus: () => provider.setRestSecs(provider.restSecs - 15),
                    onPlus: () => provider.setRestSecs(provider.restSecs + 15),
                  ),
                  _Stepper(
                    label: 'Rounds',
                    value: provider.totalRounds == 0
                        ? '∞'
                        : '${provider.totalRounds}',
                    onMinus: () => provider.setTotalRounds(provider.totalRounds - 1),
                    onPlus: () => provider.setTotalRounds(provider.totalRounds + 1),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text('“Ten seconds” warning',
                            style: TextStyle(
                                color: kTextSubtle, fontSize: kFontBase)),
                      ),
                      CupertinoSwitch(
                        value: provider.roundWarnEnabled,
                        activeTrackColor: kAccent,
                        onChanged: provider.setRoundWarnEnabled,
                      ),
                    ],
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

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });
  final String label;
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(color: kTextBright, fontSize: kFontBase)),
          ),
          _RoundBtn(icon: Icons.remove, onTap: onMinus, semantic: 'decrease $label'),
          SizedBox(
            width: 56,
            child: Center(
              child: Text(value,
                  style: const TextStyle(
                      color: kTextBright,
                      fontSize: kFontLG,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ),
          _RoundBtn(icon: Icons.add, onTap: onPlus, semantic: 'increase $label'),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.onTap, required this.semantic});
  final IconData icon;
  final VoidCallback onTap;
  final String semantic;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantic,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: kSurfaceDark,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: kAccent, size: 20),
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.label, required this.detail, required this.onTap});
  final String label;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$label preset, $detail',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: kSurfaceDark,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Text(label,
                  style: const TextStyle(
                      color: kTextBright,
                      fontSize: kFontBase,
                      fontWeight: FontWeight.w600)),
              Text(detail,
                  style: const TextStyle(color: kTextSubtle, fontSize: kFontSM)),
            ],
          ),
        ),
      ),
    );
  }
}
