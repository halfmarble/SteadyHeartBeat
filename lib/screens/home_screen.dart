import 'dart:async' show Timer;
import 'dart:math' show max, min, Random;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../build_info.dart';
import '../providers/workout_provider.dart';
import '../services/workout_service.dart';
import '../constants.dart';
import '../health_norms.dart';
import 'preferences_screen.dart';
import 'pre_workout_sheet.dart';
import 'sessions_screen.dart';
import 'how_it_works_screen.dart';
import '../utils.dart';
import '../widgets/workout_type_icon.dart';
import '../widgets/bpm_chart.dart';
import '../widgets/metric_explainer.dart';

part 'home_live_view.dart';
part 'home_idle_view.dart';
part 'home_controls.dart';
part 'home_summary.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            const Text(
              'SteadyHeartBeat',
              style: TextStyle(fontSize: kFontStat, fontWeight: FontWeight.w600, letterSpacing: 0.5),
            ),
            const SizedBox(width: 6),
            // kBuildNumber is auto-written by the Xcode "build number" build
            // phase before each iOS build, so it always matches the installed
            // build. The About line uses the same const. "+" marks a build with
            // the Plus module compiled in, so a free-core install and a plus
            // install of the same build number are distinguishable at a glance.
            Text(
              'b$kBuildNumber${context.read<WorkoutProvider>().plus.available ? '+' : ''}',
              style: const TextStyle(
                  fontSize: 10, color: Colors.white54, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: [
          // Trends hub — owner-only research surface (not part of the sellable
          // Plus scope). Customer and free builds show no trends entry point
          // at all.
          if (context.read<WorkoutProvider>().plus.trendsVisible)
            IconButton(
              tooltip: 'Trends',
              icon: const Icon(CupertinoIcons.chart_bar_square),
              onPressed: () =>
                  context.read<WorkoutProvider>().plus.openTrends(context, ''),
            ),
          IconButton(
            tooltip: 'Session history',
            icon: const Icon(CupertinoIcons.clock),
            onPressed: () => Navigator.push(
              context,
              CupertinoPageRoute(builder: (_) => const SessionsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Open preferences',
            icon: const Icon(CupertinoIcons.slider_horizontal_3),
            onPressed: () => Navigator.push(
              context,
              CupertinoPageRoute(builder: (_) => const PreferencesScreen()),
            ),
          ),
          // Glass Box "How it works" science screen — the last action.
          IconButton(
            tooltip: 'How it works',
            icon: const Icon(CupertinoIcons.info_circle),
            onPressed: () => Navigator.push(
              context,
              CupertinoPageRoute(builder: (_) => const HowItWorksScreen()),
            ),
          ),
        ],
      ),
      body: _ErrorDialogListener(
        child: SafeArea(
        // One Consumer over the live area is deliberate: every child consumes
        // per-sample data (the chart line, the subtitle's elapsed time, the
        // round countdown, and the start button's heart icon pulsing at the
        // live BPM), so a finer Selector split would not remove any rebuilds.
        // The static chrome (AppBar + actions) sits outside and reads the
        // provider via context.read — it never rebuilds on a sample.
        child: Consumer<WorkoutProvider>(
          builder: (context, provider, _) {
            final hasChart = provider.bpmHistory.isNotEmpty;
            final isStopped = provider.state == MonitoringState.stopped;
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: provider.onScreenTap,
              child: Column(
              children: [
                Expanded(
                  child: hasChart
                      ? (isStopped
                          ? _PostWorkoutView(provider: provider)
                          : _ChartView(provider: provider))
                      : _IdleView(provider: provider),
                ),
                if (provider.state == MonitoringState.running &&
                    provider.selectedWorkoutType == WorkoutType.boxing &&
                    provider.boxingRoundsEnabled)
                  _RoundBanner(provider: provider),
                if (hasChart && !isStopped)
                  _ChartSubtitle(provider: provider),
                _ControlBar(provider: provider),
              ],
            ),
            );
          },
        ),
      ),
      ),
    );
  }
}

// ── AirPods warning dialog listener ──────────────────────────────────────────

class _ErrorDialogListener extends StatefulWidget {
  const _ErrorDialogListener({required this.child});
  final Widget child;

  @override
  State<_ErrorDialogListener> createState() => _ErrorDialogListenerState();
}

class _ErrorDialogListenerState extends State<_ErrorDialogListener> {
  WorkoutProvider? _provider;
  String? _lastShownError;
  String? _lastShownSaveError;
  String? _lastShownZonesWarning;
  String? _lastShownAudioWarning;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Provider.of<WorkoutProvider>(context, listen: false);
    if (_provider != p) {
      _provider?.removeListener(_onProviderChange);
      _provider = p;
      p.addListener(_onProviderChange);
    }
  }

  bool _isAirPodsError(WorkoutProvider p) =>
      p.state == MonitoringState.error &&
      (p.errorMessage == 'AirPods not found!' ||
       (p.errorMessage?.contains('active on this iPhone') ?? false));

  void _onProviderChange() {
    final p = _provider!;
    if (_isAirPodsError(p) && _lastShownError != p.errorMessage) {
      _lastShownError = p.errorMessage;
      final title = p.errorMessage ?? 'AirPods problem';
      final steps = List<String>.from(p.errorSteps);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (_) => _AirPodsWarningDialog(title: title, steps: steps),
          );
        }
      });
    } else if (p.state != MonitoringState.error) {
      _lastShownError = null;
    }

    // Save failure → persistent SnackBar so the user actually sees it.
    if (p.saveError != null && p.saveError != _lastShownSaveError) {
      _lastShownSaveError = p.saveError;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(p.saveError!),
            duration: const Duration(seconds: 30),
            behavior: SnackBarBehavior.floating,
            backgroundColor: kErrorSnackBg,
            action: SnackBarAction(
              label: 'Dismiss',
              textColor: Colors.white,
              onPressed: () => p.clearSaveError(),
            ),
          ));
      });
    } else if (p.saveError == null) {
      _lastShownSaveError = null;
    }

    // Zones unavailable (no HealthKit DOB, no manual age) → soft warning.
    if (p.zonesWarning != null && p.zonesWarning != _lastShownZonesWarning) {
      _lastShownZonesWarning = p.zonesWarning;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(p.zonesWarning!),
            duration: const Duration(seconds: 12),
            behavior: SnackBarBehavior.floating,
            backgroundColor: kWarningSnackBg,
            action: SnackBarAction(
              label: 'OK',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ));
      });
    } else if (p.zonesWarning == null) {
      _lastShownZonesWarning = null;
    }

    // Announce audio out of action mid-workout (engine failure, or Bluetooth
    // route lost so cues are held back from the iPhone speaker) → soft
    // warning; monitoring itself continues.
    if (p.audioWarning != null && p.audioWarning != _lastShownAudioWarning) {
      _lastShownAudioWarning = p.audioWarning;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(p.audioWarning!),
            duration: const Duration(seconds: 12),
            behavior: SnackBarBehavior.floating,
            backgroundColor: kWarningSnackBg,
            action: SnackBarAction(
              label: 'OK',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ));
      });
    } else if (p.audioWarning == null) {
      _lastShownAudioWarning = null;
    }
  }

  @override
  void dispose() {
    _provider?.removeListener(_onProviderChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _AirPodsWarningDialog extends StatelessWidget {
  const _AirPodsWarningDialog({required this.title, required this.steps});

  /// The actual error from the provider — so the dialog reflects the real
  /// situation (in case / not in ears / on another device) instead of always
  /// claiming the AirPods are "bound to another device".
  final String title;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: kDialogBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kZone3, width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.warning_amber_rounded, color: kZone3, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: kZone3,
                    fontSize: kFontLG,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]),
            if (steps.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: kDialogBgLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kZone3.withAlpha(0x44)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < steps.length; i++)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('→  ',
                                style: TextStyle(
                                    color: kZone3,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700)),
                            Expanded(
                              child: Text(
                                steps[i],
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: kFontMD,
                                    height: 1.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  backgroundColor: kZone3.withAlpha(0x28),
                  foregroundColor: kZone3,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Got It',
                    style: TextStyle(fontSize: kFontLG, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
