import 'dart:async' show Timer;
import 'dart:math' show max, min, Random;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/workout_provider.dart';
import '../services/workout_service.dart';
import '../constants.dart';
import '../health_norms.dart';
import 'preferences_screen.dart';
import 'pre_workout_sheet.dart';
import 'sessions_screen.dart';
import '../utils.dart';
import '../build_info.dart';
import '../widgets/workout_type_icon.dart';
import '../widgets/metric_explainer.dart';

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
            // "+" marks a build with the SHB+ module compiled in, so an open
            // (free-core) install and a plus install of the same build number
            // are distinguishable at a glance.
            Text(
              'b$kBuildNumber${context.read<WorkoutProvider>().plus.available ? '+' : ''}',
              style: const TextStyle(fontSize: 10, color: Colors.white54, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: [
          // Trends hub — only in a build with the SHB+ module (the free core has
          // no chart; gating here keeps it from advertising a dead end).
          if (context.read<WorkoutProvider>().plus.available)
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
        ],
      ),
      body: _ErrorDialogListener(
        child: SafeArea(
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

// Chart fills the full Expanded area; BPM number floats on top, drifting away from the line.
class _ChartView extends StatelessWidget {
  const _ChartView({required this.provider, this.showOverlay = true});
  final WorkoutProvider provider;
  final bool showOverlay;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: BpmChart(
            history: provider.bpmHistory,
            smoothedBpms: provider.smoothedBpms,
            dangerThreshold: provider.dangerZoneThreshold,
            zone1End: provider.zone1End,
            zone2Start: provider.zone2Start,
            zone3Start: provider.zone3Start,
            zone4Start: provider.zone4Start,
            zone5Start: provider.zone5Start,
            // Scrub the finished session's chart; not while live.
            enableScrubber: provider.state == MonitoringState.stopped,
          ),
        ),
        if (showOverlay)
          Positioned.fill(child: _DriftingBpmOverlay(provider: provider)),
        if (provider.state == MonitoringState.error)
          Positioned(
            left: 16, right: 16, bottom: 24,
            child: _ErrorCard(message: provider.errorMessage, steps: provider.errorSteps),
          ),
      ],
    );
  }
}

// Post-workout view: portrait stacks chart above summary; landscape puts them side by side.
class _PostWorkoutView extends StatelessWidget {
  const _PostWorkoutView({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).orientation == Orientation.landscape) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _ChartView(provider: provider, showOverlay: false),
          ),
          SizedBox(
            width: 300,
            child: SingleChildScrollView(
              child: _PostWorkoutSummary(provider: provider),
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: _ChartView(provider: provider, showOverlay: false),
        ),
        _PostWorkoutSummary(provider: provider),
      ],
    );
  }
}

// BPM number that drifts 1 px/frame away from the recent heart-rate line.
class _DriftingBpmOverlay extends StatefulWidget {
  const _DriftingBpmOverlay({required this.provider});
  final WorkoutProvider provider;

  @override
  State<_DriftingBpmOverlay> createState() => _DriftingBpmOverlayState();
}

class _DriftingBpmOverlayState extends State<_DriftingBpmOverlay> {
  static const _fontSize = 96.0;

  double _portraitOffsetY = 0.0;
  double _chartHeight = 0.0;
  bool _isPortrait = true;
  bool _portraitPlaced = false;

  @override
  void initState() {
    super.initState();
    // Event-driven: fires only when provider emits (new HR data ~0.2 Hz).
    // Replaces a 60 fps Ticker that polled even with no new data — 300x
    // fewer CPU wakeups, allowing the SoC to stay in low-power states.
    widget.provider.addListener(_onProviderChange);
  }

  @override
  void didUpdateWidget(_DriftingBpmOverlay old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      old.provider.removeListener(_onProviderChange);
      widget.provider.addListener(_onProviderChange);
    }
  }

  @override
  void dispose() {
    widget.provider.removeListener(_onProviderChange);
    super.dispose();
  }

  double get _portraitBottomY =>
      (_chartHeight / 2 - _fontSize * 1.5).clamp(0.0, _chartHeight * 0.4);

  void _onProviderChange() {
    if (!mounted || _chartHeight == 0) return;
    if (!_isPortrait) return; // landscape is always centered in build()

    if (!_portraitPlaced) {
      _portraitPlaced = true;
      setState(() => _portraitOffsetY = _portraitBottomY);
      return;
    }

    final history = widget.provider.bpmHistory;
    if (history.isEmpty) return;

    // Single-pass min/max — avoids two-pass reduce() over the same list.
    var minBpm = history.first.bpm, maxBpm = history.first.bpm;
    for (final s in history) {
      if (s.bpm < minBpm) minBpm = s.bpm;
      if (s.bpm > maxBpm) maxBpm = s.bpm;
    }
    final yPad = ((maxBpm - minBpm) * 0.15).clamp(5.0, 20.0);
    final minY = minBpm - yPad, maxY = maxBpm + yPad;

    final recent = history.length > 20 ? history.sublist(history.length - 20) : history;
    final avgBpm = recent.fold(0.0, (s, e) => s + e.bpm) / recent.length;
    final normalized = ((avgBpm - minY) / (maxY - minY)).clamp(0.0, 1.0);

    final targetY = normalized < 0.30 ? -_portraitBottomY : _portraitBottomY;
    final diff = targetY - _portraitOffsetY;
    if (diff.abs() < 0.5) return;
    setState(() => _portraitOffsetY += diff.sign);
  }

  @override
  Widget build(BuildContext context) {
    final bpm = widget.provider.currentBpm;
    final text = bpm != null ? bpm.round().toString() : 'XX';
    final isError = widget.provider.state == MonitoringState.error;
    final kcal = widget.provider.currentKcal;
    final steps = widget.provider.currentSteps;
    final dist  = widget.provider.currentDistanceMeters;
    final floors = widget.provider.currentFloorsClimbed;
    _isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;

    const shadows = [
      Shadow(blurRadius: 24, color: Colors.black),
      Shadow(blurRadius: 56, color: Colors.black),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        _chartHeight = constraints.maxHeight;
        // Before the first provider callback sets _portraitPlaced, use
        // _portraitBottomY directly so the number starts at the target
        // position rather than centre. _portraitBottomY already uses the
        // freshly-updated _chartHeight, so the value is correct here.
        final offset = _isPortrait
            ? (_portraitPlaced ? _portraitOffsetY : _portraitBottomY)
            : 0.0;
        final hasSubMetrics = !isError && (steps != null || dist != null || (floors != null && floors > 0));
        return Center(
          child: Transform.translate(
            offset: Offset(0, offset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Respiratory rate — left, blue
                    if (widget.provider.currentRespiratoryRate != null && !isError) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          '${widget.provider.currentRespiratoryRate!.round()}\nbr/min',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w300,
                            color: kCyan,
                            height: 1.1,
                            shadows: shadows,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    // Heart rate number. liveRegion makes VoiceOver announce
                    // updates when the BPM value changes; ExcludeSemantics on
                    // the inner Text prevents it from being read as a bare
                    // number on top of our richer "Heart rate N beats per
                    // minute" label.
                    Semantics(
                      label: bpm != null
                          ? 'Heart rate $text beats per minute'
                          : 'Heart rate not detected',
                      liveRegion: true,
                      child: ExcludeSemantics(
                        child: Text(
                          text,
                          style: TextStyle(
                            fontSize: _fontSize,
                            fontWeight: FontWeight.w100,
                            color: isError ? kTextSubtle : Colors.white,
                            shadows: isError ? null : shadows,
                          ),
                        ),
                      ),
                    ),
                    // Calorie counter — right, yellow
                    if (kcal != null && !isError) ...[
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          '${kcal.round()}\nkcal',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w300,
                            color: kZone3,
                            height: 1.1,
                            shadows: shadows,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (hasSubMetrics) ...[
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (steps != null)
                        Text('${fmtSteps(steps)} steps',
                            style: TextStyle(fontSize: kFontLG, fontWeight: FontWeight.w300,
                                color: Colors.white70, shadows: shadows)),
                      if (steps != null && dist != null)
                        Text('  ·  ', style: TextStyle(color: kTextDim,
                            fontSize: kFontLG, shadows: shadows)),
                      if (dist != null)
                        Text(fmtDist(dist, widget.provider.useImperial),
                            style: TextStyle(fontSize: kFontLG, fontWeight: FontWeight.w300,
                                color: Colors.white70, shadows: shadows)),
                      if ((steps != null || dist != null) && floors != null && floors > 0)
                        Text('  ·  ', style: TextStyle(color: kTextDim,
                            fontSize: kFontLG, shadows: shadows)),
                      if (floors != null && floors > 0)
                        Text('${floors.round()} fl',
                            style: TextStyle(fontSize: kFontLG, fontWeight: FontWeight.w300,
                                color: Colors.white70, shadows: shadows)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ChartSubtitle extends StatelessWidget {
  const _ChartSubtitle({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    if (provider.state == MonitoringState.error) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text('sensor error',
            textAlign: TextAlign.center,
            style: TextStyle(color: kTextLabel, fontSize: kFontMD)),
      );
    }

    if (provider.state == MonitoringState.stopped) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          Text('monitoring stopped',
              textAlign: TextAlign.center,
              style: const TextStyle(color: kTextLabel, fontSize: kFontMD)),
          const SizedBox(height: 2),
          _ZoneTimeLine(provider: provider),
        ]),
      );
    }

    // Running — build a compact stats line
    if (provider.state != MonitoringState.running || provider.currentBpm == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text('waiting for sensor…',
            textAlign: TextAlign.center,
            style: TextStyle(color: kTextLabel, fontSize: kFontMD)),
      );
    }

    final deviceName = provider.airPodsName.isNotEmpty ? provider.airPodsName : 'AirPods';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        deviceName,
        textAlign: TextAlign.center,
        style: const TextStyle(color: kTextLabel, fontSize: kFontMD, letterSpacing: 0.3),
      ),
    );
  }
}

// Zone time distribution bar shown after the session ends.
class _ZoneTimeLine extends StatelessWidget {
  const _ZoneTimeLine({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    // Use precomputed zone seconds from the provider (O(1)) — avoids iterating
    // the full bpmHistory on every build after the session ends.
    final secs = provider.summaryZoneSecs;
    if (secs == null) return const SizedBox.shrink();

    final total = secs.fold(0.0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();

    const colors = kZoneColors;
    final labels = ['<50', 'Z1', 'Z2', 'Z3', 'Z4', 'Z5'];

    String fmt(double s) {
      if (s < 60) return '${s.round()}s';
      return '${(s / 60).round()}m';
    }

    // Single centered Text.rich (not a Row) so the label wraps and stays
    // horizontally centered when many zones are present — a non-wrapping Row
    // overflows and left-clips. Mirrors _ZoneBar in sessions_screen.dart. The
    // " · " separator is inserted only between rendered zones, so a zero-time
    // lowest zone leaves no leading dot.
    final spans = <InlineSpan>[
      const TextSpan(
        text: 'time in zones  ',
        style: TextStyle(color: kTextDim, fontSize: kFontCaption, letterSpacing: 0.3),
      ),
    ];
    bool any = false;
    for (int i = 0; i < 6; i++) {
      if (secs[i] <= 0) continue;
      if (any) {
        spans.add(const TextSpan(
          text: '  ·  ',
          style: TextStyle(color: kTextFaint, fontSize: kFontCaption),
        ));
      }
      any = true;
      spans.add(TextSpan(
        text: '${labels[i]} ${fmt(secs[i])}',
        style: TextStyle(color: colors[i].withAlpha(0xBB), fontSize: kFontCaption),
      ));
    }

    return Text.rich(
      TextSpan(children: spans),
      textAlign: TextAlign.center,
    );
  }
}

class _IdleView extends StatelessWidget {
  const _IdleView({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final String subtitle;
    switch (provider.state) {
      case MonitoringState.idle:
        subtitle = 'Heart rate read aloud during workouts.';
      case MonitoringState.starting:
        subtitle = 'connecting…';
      case MonitoringState.running:
        subtitle = 'waiting for sensor…';
      case MonitoringState.stopped:
        subtitle = 'monitoring stopped';
      case MonitoringState.error:
        subtitle = provider.errorMessage ?? 'sensor error';
    }

    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final isSearching = provider.state == MonitoringState.starting ||
        (provider.state == MonitoringState.running && provider.currentBpm == null);
    final showSelector = provider.state == MonitoringState.idle ||
        provider.state == MonitoringState.stopped ||
        provider.state == MonitoringState.error ||
        isSearching;
    final selectorDisabled = isSearching;
    final showMetrics = provider.effectiveHrvMs != null ||
        provider.effectiveRestingHrBpm != null ||
        provider.effectiveVo2Max != null;
    final isError = provider.state == MonitoringState.error;

    if (isLandscape) {
      return Row(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SensorSearchIndicator(isActive: isSearching, isDisabled: !isSearching && provider.state != MonitoringState.running, size: 130),
                  SizedBox(
                    height: 22,
                    child: provider.state == MonitoringState.idle
                        ? Center(child: _AirPodsStatusRow(provider: provider))
                        : null,
                  ),
                  // Fixed-height slot keeps AirPods position invariant when subtitle appears.
                  SizedBox(
                    height: 30,
                    child: subtitle.isNotEmpty
                        ? Center(child: Text(subtitle,
                              style: TextStyle(color: isError ? kAccent : kTextLabel, fontSize: 14, letterSpacing: 0.3)))
                        : null,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Padding(
                  // Right inset trimmed 16→4 so the mode selector extends 12px
                  // further right in landscape (matches the Start button below).
                  padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showMetrics) ...[
                        _PreWorkoutMetrics(provider: provider),
                        const SizedBox(height: 20),
                      ],
                      if (showSelector)
                        _WorkoutTypeSelector(provider: provider, disabled: selectorDisabled),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 40),
        SizedBox(
          height: 180,
          child: Center(child: _SensorSearchIndicator(isActive: isSearching, isDisabled: !isSearching && provider.state != MonitoringState.running)),
        ),
        SizedBox(
          height: 22,
          child: provider.state == MonitoringState.idle
              ? Center(child: _AirPodsStatusRow(provider: provider))
              : null,
        ),
        SizedBox(
          height: 30,
          child: subtitle.isNotEmpty
              ? Center(child: Text(subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: isError ? kAccent : kTextLabel, fontSize: 14, letterSpacing: 0.3)))
              : null,
        ),
        const Spacer(),
        if (showMetrics) ...[
          _PreWorkoutMetrics(provider: provider),
          const SizedBox(height: 20),
        ],
        if (showSelector)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _WorkoutTypeSelector(provider: provider, disabled: selectorDisabled),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _AirPodsStatusRow extends StatelessWidget {
  const _AirPodsStatusRow({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final Color dot;
    final String text;
    final rawName = provider.idleAirPodsName;
    final name = rawName.isNotEmpty ? '‘$rawName’' : 'AirPods';
    if (!provider.idleAirPodsConnected) {
      dot = kZone3;
      text = 'Connect your AirPods';
    } else if (!provider.idleAirPodsActiveHere) {
      dot = kZone3;
      text = '$name on another device';
    } else {
      dot = kZone1;
      text = '$name connected';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(color: kTextMuted, fontSize: kFontMD, letterSpacing: 0.2),
        ),
      ],
    );
  }
}

// ── Boxing round banner ──────────────────────────────────────────────────────

/// Compact round display shown during a boxing workout with the round timer on.
/// The countdown + round count come from native 'round' status events (the
/// source of truth, since the clock is native-side). Display-only: there's no
/// pause control — once the gloves are on you can't tap the screen anyway.
class _RoundBanner extends StatelessWidget {
  const _RoundBanner({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final phase = provider.roundPhase;
    // During an SHB+ module-driven phase (e.g. an HR-gated warm-up) the module
    // supplies its own panel instead of the countdown banner. Null in the free
    // core and outside gated phases.
    final plusBanner = provider.plus.roundBanner(context, phase);
    if (plusBanner != null) return plusBanner;
    final isWork = phase == 'work';
    final (String label, Color color) = switch (phase) {
      'prep' => ('GET READY', kTextLabel),
      'work' => (
          provider.roundTotal > 0
              ? 'ROUND ${provider.currentRound}/${provider.roundTotal}'
              : 'ROUND ${provider.currentRound}',
          kAccent),
      'rest' => ('REST', kZone1),
      _ => ('DONE', kTextLabel),
    };
    final secs = provider.roundRemaining;
    final mmss = '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';

    return Container(
      // Full-bleed to match the chart width above it.
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: kSurface,
        border: Border(
          top: BorderSide(color: isWork ? kAccent : kStopButton, width: 1),
          bottom: BorderSide(color: isWork ? kAccent : kStopButton, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: kFontMD,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
          Text(mmss,
              style: const TextStyle(
                  color: kTextBright,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [ui.FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _PreWorkoutMetrics extends StatelessWidget {
  const _PreWorkoutMetrics({required this.provider});
  final WorkoutProvider provider;

  static String _age(DateTime? date) {
    if (date == null) return '';
    final d = DateTime.now().difference(date);
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final metrics = <Widget>[];

    // Age label: "manual" when overridden, amber when the auto value is stale.
    String ageLabel(bool manual, DateTime? date) =>
        manual ? 'manual' : _age(date);
    Color ageTint(bool manual, bool stale) =>
        manual ? kTextMuted : (stale ? kZone3 : kTextFaint);

    // Age for grading HRV/VO₂max against age-appropriate norms (see
    // health_norms.dart). Falls back to a mid-adult reference when DOB/age is
    // unknown — same spirit as the old single fixed thresholds.
    final normAge = provider.healthAge ?? 45;
    final normFemale = provider.effectiveSex == 'female';
    // The daily-trends chart is an SHB+ surface; only attach the tap-to-trends
    // affordance in a build that has the module (free core has no chart).
    final trends = provider.plus.available;

    // HRV — SDNN graded against age-banded norms (declines with age).
    if (provider.effectiveHrvMs != null) {
      final ms = provider.effectiveHrvMs!;
      final hrvB = hrvSdnnBands(normAge);
      final c = ms >= hrvB.good ? kZone1
              : ms >= hrvB.moderate ? kZone3
              : kAccent;
      final manual = provider.manualHrvMs != null;
      // An auto value averaged over last night's whole in-bed span is the
      // cleaner resting reading — label it "bed HRV". A manual override or a
      // single-sample fallback stays the generic "resting HRV".
      final overnight = !manual && provider.hrvSource == 'bed';
      metrics.add(_Metric(
        label: overnight ? 'bed HRV' : 'resting HRV',
        prefix: 'HRV',
        value: ms.round().toString(),
        unit: 'ms',
        color: c,
        age: ageLabel(manual, provider.recentHrvDate),
        ageColor: ageTint(manual, provider.hrvStale),
        infoKey: overnight ? 'bedHrv' : 'restingHrv',
        // Tap the bed HRV value → daily-trends hub (SHB+; teaser when locked).
        onValueTap: (overnight && trends)
            ? () => provider.plus.openTrends(context, 'bedHrv')
            : null,
      ));
    }

    // Resting HR — <55 athletic, 55–70 good, 70–85 average, >85 elevated
    if (provider.effectiveRestingHrBpm != null) {
      final bpm = provider.effectiveRestingHrBpm!;
      final c = bpm < 55 ? kZone1
              : bpm < 70 ? kZone2
              : bpm < 85 ? kZone3
              : kAccent;
      final manual = provider.manualRestingHr != null;
      // An auto value averaged over last night's whole in-bed span is labelled
      // "bed HR"; a manual override or single-sample fallback stays "resting HR".
      final overnight = !manual && provider.restingHrSource == 'bed';
      metrics.add(_Metric(
        label: overnight ? 'bed HR' : 'resting HR',
        prefix: '❤',
        value: bpm.round().toString(),
        unit: 'bpm',
        color: c,
        age: ageLabel(manual, provider.recentRestingHrDate),
        ageColor: ageTint(manual, provider.restingHrStale),
        infoKey: overnight ? 'bedHr' : 'restingHr',
        onValueTap: (overnight && trends)
            ? () => provider.plus.openTrends(context, 'bedHr')
            : null,
      ));
    }

    // VO₂ max graded against age-banded ACSM/Cooper men's norms (declines with
    // age) — see health_norms.dart.
    if (provider.effectiveVo2Max != null) {
      final v = provider.effectiveVo2Max!;
      final vo2B = vo2maxBands(normAge, female: normFemale);
      final c = v >= vo2B.excellent ? kZone1
              : v >= vo2B.good ? kZone2
              : v >= vo2B.fair ? kZone3
              : kAccent;
      final manual = provider.manualVo2Max != null;
      metrics.add(_Metric(
        label: 'VO₂ max',
        prefix: 'VO₂',
        value: v.round().toString(),
        unit: 'ml/kg/min',
        color: c,
        age: ageLabel(manual, provider.recentVo2MaxDate),
        ageColor: ageTint(manual, provider.vo2Stale),
        infoKey: 'vo2max',
        onValueTap:
            trends ? () => provider.plus.openTrends(context, 'vo2max') : null,
      ));
    }

    if (metrics.isEmpty) return const SizedBox.shrink();

    // Interleave with thin vertical dividers
    final children = <Widget>[];
    for (int i = 0; i < metrics.length; i++) {
      if (i > 0) {
        children.add(Container(
          width: 1, height: 40,
          color: kStopButton,
          margin: const EdgeInsets.symmetric(horizontal: 20),
        ));
      }
      children.add(metrics[i]);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.prefix,
    required this.value,
    required this.unit,
    required this.color,
    required this.age,
    this.ageColor = kTextFaint,
    this.infoKey,
    this.onValueTap,
  });
  final String label, prefix, value, unit, age;
  final Color color;
  final Color ageColor;
  // Key into kMetricExplainers; null = no ⓘ affordance. The ⓘ (on the label) is
  // a distinct tap target from [onValueTap] (the value → daily-trends chart).
  final String? infoKey;
  // Tapping the value opens the metric's daily-trends chart (SHB+), via the
  // plus plug point — a teaser when locked. Null = value not tappable.
  final VoidCallback? onValueTap;

  @override
  Widget build(BuildContext context) {
    const labelStyle =
        TextStyle(color: kTextDim, fontSize: kFontSM, letterSpacing: 0.4);
    final Widget labelRow = infoKey == null
        ? Text(label, style: labelStyle)
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showMetricExplainer(context, infoKey!),
            child: Padding(
              // A little vertical padding turns the thin label into an easier
              // tap target; every chip carries an ⓘ so they stay row-aligned.
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: labelStyle),
                  const SizedBox(width: 3),
                  const Icon(CupertinoIcons.info_circle,
                      size: 12, color: kTextDim),
                ],
              ),
            ),
          );
    final Widget valueText = RichText(
      text: TextSpan(children: [
        TextSpan(
          text: '$prefix  ',
          style: TextStyle(
            color: color.withAlpha(0xAA),
            fontSize: kFontCaption,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.4,
          ),
        ),
        TextSpan(
          text: value,
          style: TextStyle(color: color, fontSize: kFontDisplay, fontWeight: FontWeight.w200),
        ),
        TextSpan(
          text: '  $unit',
          style: TextStyle(color: color.withAlpha(0xAA), fontSize: kFontSM),
        ),
      ]),
    );
    return Column(
      children: [
        labelRow,
        const SizedBox(height: 4),
        onValueTap == null
            ? valueText
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onValueTap,
                // A small chart glyph makes the value visibly tappable (→ the
                // daily-trends hub) rather than relying on an invisible tap.
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    valueText,
                    const SizedBox(width: 4),
                    Icon(Icons.show_chart, size: 13, color: color.withAlpha(0xAA)),
                  ],
                ),
              ),
        if (age.isNotEmpty)
          Text(age, style: TextStyle(color: ageColor, fontSize: kFontSM)),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, this.steps = const []});
  final String? message;
  final List<String> steps;

  // True for errors the user resolves in iOS Settings (permissions). Shows an
  // "Open Settings" button so they don't have to leave the app manually and
  // try to remember why they left.
  bool get _isSettingsError {
    final m = message?.toLowerCase() ?? '';
    return m.contains('health access') || m.contains('permission');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kErrorBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Headline
            Row(children: [
              const Icon(CupertinoIcons.exclamationmark_circle,
                  color: kAccent, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message ?? 'Unknown error',
                  style: const TextStyle(
                    color: kAccent,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]),
            if (_isSettingsError) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 40,
                child: FilledButton(
                  onPressed: () => launchUrl(Uri.parse('app-settings:')),
                  style: FilledButton.styleFrom(
                    backgroundColor: kSurface,
                    foregroundColor: kAccent,
                    side: const BorderSide(color: kAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Open Settings'),
                ),
              ),
            ],
            if (steps.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text(
                'TRY THIS',
                style: TextStyle(
                  color: kTextSubtle,
                  fontSize: kFontSM,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 8),
              ...steps.asMap().entries.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 20,
                      child: Text(
                        '${e.key + 1}.',
                        style: const TextStyle(
                          color: kTextDim,
                          fontSize: kFontMD,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        e.value,
                        style: const TextStyle(
                          color: kTextMuted,
                          fontSize: kFontMD,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              )),
            ],
          ],
        ),
      ),
    );
  }
}

// Workout type icon for action buttons — red, beats at current BPM when running.
class _ButtonWorkoutIcon extends StatefulWidget {
  const _ButtonWorkoutIcon({required this.type, required this.state, this.bpm});
  final WorkoutType type;
  final MonitoringState state;
  final double? bpm;

  @override
  State<_ButtonWorkoutIcon> createState() => _ButtonWorkoutIconState();
}

class _ButtonWorkoutIconState extends State<_ButtonWorkoutIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double> _scale;

  static Animation<double> _buildScale(AnimationController ctrl) =>
      TweenSequence<double>([
        TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 1.3).chain(CurveTween(curve: Curves.easeOut)),
          weight: 14,
        ),
        TweenSequenceItem(
          tween: Tween(begin: 1.3, end: 1.0).chain(CurveTween(curve: Curves.easeIn)),
          weight: 16,
        ),
        TweenSequenceItem(tween: ConstantTween(1.0), weight: 70),
      ]).animate(ctrl);

  Duration _beatDuration() =>
      Duration(milliseconds: (60000 / (widget.bpm ?? 70).clamp(30, 220)).round());

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: _beatDuration());
    _scale = _buildScale(_pulse);
    _updateAnimation();
  }

  @override
  void didUpdateWidget(_ButtonWorkoutIcon old) {
    super.didUpdateWidget(old);
    if (old.bpm != widget.bpm) _pulse.duration = _beatDuration();
    if (old.state != widget.state || old.bpm != widget.bpm) _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.state == MonitoringState.running) {
      _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.reset();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = _icon();
    if (widget.state != MonitoringState.running) return icon;
    return ScaleTransition(scale: _scale, child: icon);
  }

  Widget _icon() =>
      WorkoutTypeIcon(type: widget.type, size: 22, color: kAccent);
}

const double kSensorIndicatorSize = 180;

// AirPods image: grey+faded when disabled, static when idle, breathing when searching.
class _SensorSearchIndicator extends StatefulWidget {
  const _SensorSearchIndicator({this.isActive = false, this.isDisabled = false, this.size = kSensorIndicatorSize});
  final bool isActive;
  final bool isDisabled;
  final double size;

  @override
  State<_SensorSearchIndicator> createState() => _SensorSearchIndicatorState();
}

class _SensorSearchIndicatorState extends State<_SensorSearchIndicator>
    with SingleTickerProviderStateMixin {
  static Uint8List? _cachedBytes;
  static bool _fetchAttempted = false;
  static ui.Image? _cachedUiImage;

  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;
  Uint8List? _iconBytes;
  ui.Image? _uiImage;
  int _noiseSeed = 0;
  Timer? _noiseTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _scale = Tween<double>(begin: 0.88, end: 1.05)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    _opacity = Tween<double>(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    if (_cachedBytes != null) {
      _iconBytes = _cachedBytes;
      if (_cachedUiImage != null) {
        _uiImage = _cachedUiImage;
      } else {
        _decodeUiImage(_cachedBytes!);
      }
    } else {
      _loadIcon();
    }
    // The dissolve-noise animates continuously (idle, disabled, and searching)
    // — the shimmering AirPods indicator is wanted on the home screen between
    // workouts, not just while searching. Only the breathing scale/opacity is
    // gated on isActive.
    _startNoise();
    if (widget.isActive) _ctrl.repeat(reverse: true);
  }

  Future<void> _loadIcon() async {
    if (_fetchAttempted) return;
    _fetchAttempted = true;
    await Future.delayed(const Duration(milliseconds: 800));
    try {
      final bytes = await WorkoutService().getAirPodsIcon(pointSize: 120);
      _cachedBytes = bytes;
      if (mounted && bytes != null) {
        setState(() => _iconBytes = bytes);
        await _decodeUiImage(bytes);
      }
    } catch (_) {}
  }

  Future<void> _decodeUiImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _cachedUiImage = frame.image;
      codec.dispose();
      if (mounted) setState(() => _uiImage = frame.image);
    } catch (_) {}
  }

  void _startNoise() {
    if (_noiseTimer != null) return;
    _noiseTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (mounted) setState(() => _noiseSeed++);
    });
  }

  @override
  void didUpdateWidget(_SensorSearchIndicator old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      // Noise runs continuously (started in initState); only the breathing
      // scale/opacity follows isActive.
      if (widget.isActive) {
        _ctrl.repeat(reverse: true);
      } else {
        _ctrl.stop();
        _ctrl.reset();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _noiseTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    if (_iconBytes == null) return SizedBox(width: s, height: s);

    // Active search: animated noise composited onto icon via CustomPainter.
    if (widget.isActive && _uiImage != null) {
      return FadeTransition(
        opacity: _opacity,
        child: ScaleTransition(
          scale: _scale,
          child: SizedBox(
            width: s, height: s,
            child: CustomPaint(
              painter: _SearchNoisePainter(image: _uiImage!, seed: _noiseSeed),
            ),
          ),
        ),
      );
    }

    if (widget.isDisabled && _uiImage != null) {
      return Opacity(
        opacity: kOpacityDisabled,
        child: SizedBox(
          width: s, height: s,
          child: CustomPaint(
            painter: _SearchNoisePainter(image: _uiImage!, seed: _noiseSeed),
          ),
        ),
      );
    }

    // Idle / running (not disabled, not active searching): noise without breathing.
    if (!widget.isDisabled && _uiImage != null) {
      return SizedBox(
        width: s, height: s,
        child: CustomPaint(
          painter: _SearchNoisePainter(image: _uiImage!, seed: _noiseSeed),
        ),
      );
    }

    Widget image = Image.memory(_iconBytes!, width: s, fit: BoxFit.contain);

    if (!widget.isActive) return image;
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(scale: _scale, child: image),
    );
  }
}

// BoxFit.contain rect: centres image within size preserving aspect ratio.
Rect _containRect(ui.Image image, Size size) {
  final iw = image.width.toDouble();
  final ih = image.height.toDouble();
  final scale = min(size.width / iw, size.height / ih);
  final dw = iw * scale;
  final dh = ih * scale;
  return Rect.fromLTWH((size.width - dw) / 2, (size.height - dh) / 2, dw, dh);
}

// Animated dissolve noise for search state — same dstOut alpha-hole effect as
// the disabled state, but the seed changes each frame so the holes shift.
class _SearchNoisePainter extends CustomPainter {
  const _SearchNoisePainter({required this.image, required this.seed});
  final ui.Image image;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());

    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.drawImageRect(image, src, _containRect(image, size), Paint());

    final rng = Random(seed);
    final paint = Paint()..blendMode = BlendMode.dstOut;
    for (int y = 0; y < size.height; y += 2) {
      for (int x = 0; x < size.width; x += 2) {
        if (rng.nextDouble() < 0.38) {
          paint.color = Color.fromRGBO(0, 0, 0, rng.nextDouble() * 0.75 + 0.15);
          canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1.5, 1.5), paint);
        }
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SearchNoisePainter old) => old.seed != seed;
}


class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final state = provider.state;
    // In landscape, trim the right inset 16→4 so the control bar extends 12px
    // further right, matching the mode selector.
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, isLandscape ? 4 : 16, 32),
      child: switch (state) {
        MonitoringState.starting => const _LoadingButton(),
        MonitoringState.running  => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: 'Stop workout',
              child: FilledButton(
                onPressed: () => provider.stop(),
                style: FilledButton.styleFrom(
                  backgroundColor: kStopButton,
                  minimumSize: const Size(double.infinity, kButtonHeight),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kButtonRadius)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ExcludeSemantics(child: _ButtonWorkoutIcon(type: provider.selectedWorkoutType, state: state, bpm: provider.currentBpm)),
                    const SizedBox(width: 10),
                    const Text('Stop Workout',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
        MonitoringState.stopped => Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: 'New workout',
                child: FilledButton(
                  onPressed: () => provider.resetToIdle(),
                  style: FilledButton.styleFrom(
                    backgroundColor: kStopButton,
                    minimumSize: const Size(0, kButtonHeight),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kButtonRadius)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ExcludeSemantics(child: _ButtonWorkoutIcon(type: provider.selectedWorkoutType, state: state, bpm: null)),
                      const SizedBox(width: 10),
                      const Text('Save',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                button: true,
                label: 'Discard',
                child: FilledButton(
                  onPressed: () => provider.discardCurrentSession(),
                  style: FilledButton.styleFrom(
                    backgroundColor: kStopButton,
                    minimumSize: const Size(0, kButtonHeight),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kButtonRadius)),
                  ),
                  child: const Text('Discard',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
        _ => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: 'Start workout',
              child: FilledButton(
                onPressed: () => maybeStartWorkout(context, provider),
                style: FilledButton.styleFrom(
                  backgroundColor: kStopButton,
                  minimumSize: const Size(double.infinity, kButtonHeight),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kButtonRadius)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ExcludeSemantics(child: _ButtonWorkoutIcon(type: provider.selectedWorkoutType, state: state, bpm: provider.currentBpm)),
                    const SizedBox(width: 10),
                    const Text('Start Workout',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
      },
    );
  }
}

class _LoadingButton extends StatelessWidget {
  const _LoadingButton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kStopButton,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
            ),
            SizedBox(width: 12),
            Text('Connecting…',
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

// ── Zone edge indicator strip ─────────────────────────────────────────────────

class _ZoneEdgeIndicator extends StatelessWidget {
  const _ZoneEdgeIndicator({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 14,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      color: Color.fromARGB(40, color.r.round(), color.g.round(), color.b.round()),
      alignment: Alignment.centerRight,
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.w600, letterSpacing: 0.2),
      ),
    );
  }
}

// ── BPM chart ─────────────────────────────────────────────────────────────────

class BpmChart extends StatelessWidget {
  const BpmChart({
    super.key,
    required this.history,
    required this.smoothedBpms,
    required this.dangerThreshold,
    this.zone1End,
    this.zone2Start,
    this.zone3Start,
    this.zone4Start,
    this.zone5Start,
    this.enableScrubber = false,
  });
  final List<BpmSample> history;
  final List<double> smoothedBpms; // pre-computed by provider (O(1) update)
  final int dangerThreshold;
  // When true (saved / post-workout charts, landscape only), dragging a finger
  // across the chart shows a white crosshair + dot and a "N bpm / time" readout.
  final bool enableScrubber;
  final int? zone1End;
  final int? zone2Start;
  final int? zone3Start;
  final int? zone4Start;
  final int? zone5Start;


  static const _minWindowSeconds = 900.0;
  static const _yTickInterval = 10.0;

  // Builds a vertical gradient mapping absolute BPM values to zone colours.
  // All 5 zones have distinct colours; Zone 4→5 uses quadratic easing.
  static LinearGradient _zoneGradient({
    required double minY, required double maxY,
    required double dangerY,
    required double z1, required double z2, required double z3,
    required double z4, required double z5,
    required bool hasAllZones,
    required int? zone1End, required int? zone2Start, required int? zone3Start,
    required int? zone4Start, required int? zone5Start,
  }) {
    const bradycardia = kBradycardiaThreshold;

    double s(double bpm) => ((bpm - minY) / (maxY - minY)).clamp(0.0, 1.0);

    Color colorAt(double bpm) {
      if (bpm <= bradycardia) return kZone5; // below bradycardia → red
      if (!hasAllZones) {
        if (bpm >= dangerY) return kZone5;
        final t = ((bpm - bradycardia) / (dangerY - bradycardia).clamp(1.0, double.infinity)).clamp(0.0, 1.0);
        return Color.lerp(kZone1, kZone5, t * t)!;
      }
      if (bpm >= z5) return kZone5;
      if (bpm >= z4) {
        // Zone 4→5: quadratic orange→red
        final t = ((bpm - z4) / (z5 - z4).clamp(1.0, double.infinity)).clamp(0.0, 1.0);
        return Color.lerp(kZone4, kZone5, t * t)!;
      }
      if (bpm >= z3) {
        // Zone 3→4: linear yellow→orange
        final t = ((bpm - z3) / (z4 - z3).clamp(1.0, double.infinity)).clamp(0.0, 1.0);
        return Color.lerp(kZone3, kZone4, t)!;
      }
      if (bpm >= z2) {
        // Zone 2→3: linear chartreuse→yellow
        final t = ((bpm - z2) / (z3 - z2).clamp(1.0, double.infinity)).clamp(0.0, 1.0);
        return Color.lerp(kZone2, kZone3, t)!;
      }
      if (bpm >= z1) {
        // Zone 1→2: linear green→chartreuse
        final t = ((bpm - z1) / (z2 - z1).clamp(1.0, double.infinity)).clamp(0.0, 1.0);
        return Color.lerp(kZone1, kZone2, t)!;
      }
      // bradycardia→zone1: amber→green
      final t = ((bpm - bradycardia) / (z1 - bradycardia).clamp(1.0, double.infinity)).clamp(0.0, 1.0);
      return Color.lerp(kZoneTransition, kZone1, t)!;
    }

    final stops  = <double>[];
    final colors = <Color>[];

    void add(double bpm, Color c) {
      final st = s(bpm);
      if (stops.isNotEmpty && (st - stops.last).abs() < 0.001) return;
      stops.add(st);
      colors.add(c);
    }

    stops.add(0.0);
    colors.add(colorAt(minY));

    if (bradycardia > minY && bradycardia < maxY) {
      add(bradycardia - 0.5, kZone5);
      add(bradycardia + 0.5, colorAt(bradycardia + 1));
    }

    if (hasAllZones) {
      for (final boundary in [z1, z2, z3]) {
        if (boundary > minY && boundary < maxY) {
          add(boundary - 0.5, colorAt(boundary - 1));
          add(boundary + 0.5, colorAt(boundary + 1));
        }
      }
      // Zone 4→5: add interpolation points for smooth quadratic
      if (z4 < maxY) {
        add(z4 - 0.5, kZone4);
        final span = (z5 - z4).clamp(1.0, double.infinity);
        for (int i = 1; i <= 6; i++) {
          final bpm = z4 + (i / 6.0) * span;
          if (bpm > minY && bpm < maxY) add(bpm, colorAt(bpm));
        }
      }
    } else {
      final span = (dangerY - bradycardia).clamp(1.0, double.infinity);
      for (int i = 1; i <= 8; i++) {
        final bpm = bradycardia + (i / 8.0) * span;
        if (bpm > minY && bpm < maxY) add(bpm, colorAt(bpm));
      }
    }

    if (stops.last < 0.999) {
      stops.add(1.0); colors.add(colorAt(maxY));
    } else {
      stops[stops.length - 1] = 1.0;
      colors[colors.length - 1] = colorAt(maxY);
    }

    return LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: colors,
      stops: stops,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use provider-cached smoothed list (incremental O(1) update per sample).
    final n = min(history.length, smoothedBpms.length);
    final spots = List.generate(
        n, (i) => FlSpot(history[i].secondsFromStart, smoothedBpms[i]));
    final maxX = max(_minWindowSeconds, history.last.secondsFromStart);

    // Single-pass min/max — avoids creating a temporary iterable.
    var minBpm = history.first.bpm, maxBpm = history.first.bpm;
    for (final s in history) {
      if (s.bpm < minBpm) minBpm = s.bpm;
      if (s.bpm > maxBpm) maxBpm = s.bpm;
    }
    final yPad = ((maxBpm - minBpm) * 0.15).clamp(5.0, 20.0);
    final minY = (minBpm - yPad).floorToDouble();
    final dangerY = dangerThreshold.toDouble();
    final maxY = (maxBpm + yPad).ceilToDouble();

    final gridXInterval = maxX / 20.0;
    // Pick a round, minute-based label interval targeting ~6 labels. The old
    // (maxX / 5).clamp(60, 600) capped at 10-minute spacing, which crammed 13
    // overlapping labels onto a 2-hour session. Snap up to the next "nice"
    // value so labels stay round (0m, 20m, 40m…) at any duration.
    const niceXIntervals = <double>[
      60, 120, 180, 300, 600, 900, 1200, 1800, 3600, 7200,
    ];
    final rawXInterval = maxX / 6.0;
    final labelXInterval = niceXIntervals.firstWhere(
      (s) => s >= rawXInterval,
      orElse: () => niceXIntervals.last,
    );
    final yRange = maxY - minY;
    final gridYInterval = (yRange / 10.0).clamp(1.0, _yTickInterval);

    const bradycardiaThreshold = 50.0;
    final hasAllZones = zone1End != null && zone2Start != null &&
        zone3Start != null && zone4Start != null && zone5Start != null;
    final z1 = zone1End?.toDouble()   ?? bradycardiaThreshold;
    final z2 = zone2Start?.toDouble() ?? z1;
    final z3 = zone3Start?.toDouble() ?? z1;
    final z4 = zone4Start?.toDouble() ?? dangerY;
    final z5 = zone5Start?.toDouble() ?? dangerY;

    // ── Zone bands — clamped to [minY, maxY] to prevent axis-area bleed ───────
    bool inRange(double lo, double hi) => lo < maxY && hi > minY;
    double lo(double v) => v.clamp(minY, maxY);
    double hi(double v) => v.clamp(minY, maxY);

    final zoneBands = hasAllZones
        ? [
            if (bradycardiaThreshold > minY)
              HorizontalRangeAnnotation(y1: minY, y2: lo(bradycardiaThreshold), color: kZoneBrady.withAlpha(kAlphaZoneBand)),
            if (inRange(bradycardiaThreshold, z1))
              HorizontalRangeAnnotation(y1: lo(max(bradycardiaThreshold, minY)), y2: hi(z1), color: kZoneTransition.withAlpha(kAlphaZoneBand)),
            if (inRange(z1, z2))
              HorizontalRangeAnnotation(y1: lo(z1), y2: hi(z2), color: kZone1.withAlpha(kAlphaZoneBand)),
            if (inRange(z2, z3))
              HorizontalRangeAnnotation(y1: lo(z2), y2: hi(z3), color: kZone2.withAlpha(kAlphaZoneBand)),
            if (inRange(z3, z4))
              HorizontalRangeAnnotation(y1: lo(z3), y2: hi(z4), color: kZone3.withAlpha(kAlphaZoneBand)),
            if (inRange(z4, z5))
              HorizontalRangeAnnotation(y1: lo(z4), y2: hi(z5), color: kZone4.withAlpha(kAlphaZoneBand)),
            if (z5 < maxY)
              HorizontalRangeAnnotation(y1: lo(z5), y2: maxY, color: kZone5.withAlpha(kAlphaZoneBand)),
          ]
        : [
            if (bradycardiaThreshold > minY)
              HorizontalRangeAnnotation(y1: minY, y2: lo(bradycardiaThreshold), color: kZoneBrady.withAlpha(kAlphaZoneBand)),
            if (dangerY < maxY)
              HorizontalRangeAnnotation(y1: lo(dangerY), y2: maxY, color: kAccent.withAlpha(kAlphaZoneBand)),
          ];

    // ── Threshold lines ───────────────────────────────────────────────────────
    HorizontalLine zoneLine(double y, Color c, String label, {bool left = false}) =>
        HorizontalLine(
          y: y, color: c.withAlpha(0xBB), strokeWidth: 1, dashArray: [4, 4],
          label: HorizontalLineLabel(
            show: true,
            alignment: left ? Alignment.topLeft : Alignment.topRight,
            padding: left
                ? const EdgeInsets.only(left: 6, top: 2)
                : const EdgeInsets.only(right: 6, bottom: 2),
            labelResolver: (_) => label,
            style: TextStyle(color: c.withAlpha(0xBB), fontSize: 9),
          ),
        );

    final zoneLines = [
      if (bradycardiaThreshold > minY && bradycardiaThreshold < maxY)
        zoneLine(bradycardiaThreshold, kZone5, '50 bpm'),
      if (hasAllZones) ...[
        if (z1 > minY && z1 < maxY) zoneLine(z1, kZone1, '$zone1End bpm', left: true),
        if (z2 > minY && z2 < maxY) zoneLine(z2, kZone2, '$zone2Start bpm', left: true),
        if (z3 > minY && z3 < maxY) zoneLine(z3, kZone3, '$zone3Start bpm'),
        if (z4 > minY && z4 < maxY) zoneLine(z4, kZone4, '$zone4Start bpm'),
        if (z5 > minY && z5 < maxY) zoneLine(z5, kZone5, '$zone5Start bpm'),
      ] else ...[
        if (dangerY > minY && dangerY < maxY) zoneLine(dangerY, kZone5, '$dangerThreshold bpm'),
      ],
    ];

    // ── Edge indicators for out-of-range zones ────────────────────────────────
    // Edge indicators for zones outside the visible chart range
    String? highEdgeLabel;
    Color? highEdgeColor;
    {
      final parts = <String>[];
      if (!hasAllZones && dangerY >= maxY) {
        parts.add('$dangerThreshold'); highEdgeColor = kZone5;
      } else if (hasAllZones) {
        if (z3 >= maxY) { parts.add('$zone3Start'); highEdgeColor ??= kZone3; }
        if (z4 >= maxY) { parts.add('$zone4Start'); highEdgeColor = kZone4; }
        if (z5 >= maxY) { parts.add('$zone5Start'); highEdgeColor = kZone5; }
      }
      if (parts.isNotEmpty) highEdgeLabel = '▲  ${parts.join('  ·  ')} bpm';
    }

    String? lowEdgeLabel;
    Color? lowEdgeColor;
    {
      final parts = <String>[];
      if (hasAllZones) {
        if (z2 <= minY) { parts.add('$zone2Start'); lowEdgeColor ??= kZone2; }
        if (z1 <= minY) { parts.add('$zone1End');   lowEdgeColor ??= kZone1; }
      }
      if (bradycardiaThreshold <= minY) { parts.add('50'); lowEdgeColor ??= kZone5; }
      if (parts.isNotEmpty) lowEdgeLabel = '▼  ${parts.join('  ·  ')} bpm';
    }

    // Scrubber: enabled for saved / post-workout charts, landscape only —
    // the wide chart gives room for precise scrubbing.
    final scrub = enableScrubber &&
        MediaQuery.of(context).orientation == Orientation.landscape;

    final chart = LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        lineTouchData: scrub
            ? LineTouchData(
                enabled: true,
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => kSurface,
                  tooltipRoundedRadius: 6,
                  tooltipPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  getTooltipItems: (spots) => spots
                      .map((s) => LineTooltipItem(
                            '${s.y.round()} bpm',
                            const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13),
                            children: [
                              TextSpan(
                                text: '\n${fmtDuration(s.x.round())}',
                                style: const TextStyle(
                                    color: kTextSubtle,
                                    fontWeight: FontWeight.w400,
                                    fontSize: 11),
                              ),
                            ],
                          ))
                      .toList(),
                ),
                getTouchedSpotIndicator: (bar, indexes) => indexes
                    .map((i) => TouchedSpotIndicatorData(
                          const FlLine(color: Colors.white, strokeWidth: 1),
                          FlDotData(
                            getDotPainter: (spot, pct, b, idx) =>
                                FlDotCirclePainter(
                              radius: 4.5,
                              color: Colors.white,
                              strokeColor: kBackground,
                              strokeWidth: 2,
                            ),
                          ),
                        ))
                    .toList(),
              )
            : const LineTouchData(enabled: false),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: zoneBands,
        ),
        extraLinesData: ExtraLinesData(horizontalLines: zoneLines),
        gridData: FlGridData(
          show: true,
          horizontalInterval: gridYInterval,
          verticalInterval: gridXInterval,
          getDrawingHorizontalLine: (_) => const FlLine(color: kChartGrid, strokeWidth: 1),
          getDrawingVerticalLine: (_) => const FlLine(color: kChartGrid, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          // 8 px reserved at top prevents the topmost Y label from being clipped
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false, reservedSize: 8)),
          rightTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: gridYInterval,
              reservedSize: 42,
              getTitlesWidget: (value, meta) {
                const halfLine = 7.0;
                if (meta.axisPosition < halfLine ||
                    meta.axisPosition > meta.parentAxisSize - halfLine) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    '${value.round()}',
                    style: const TextStyle(color: kTextSubtle, fontSize: kFontSM),
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: labelXInterval,
              reservedSize: 22,
              getTitlesWidget: (value, _) => Text(
                '${(value / 60).round()}m',
                style: const TextStyle(color: kTextSubtle, fontSize: kFontSM),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: gridYInterval,
              reservedSize: 36,
              getTitlesWidget: (value, meta) {
                // Dynamically suppress labels whose pixel position would put
                // them within half a line-height of the chart edge (they would
                // be clipped by fl_chart's clip boundary).
                const halfLine = 7.0; // ~half of 10 px font + 2 px margin
                if (meta.axisPosition < halfLine ||
                    meta.axisPosition > meta.parentAxisSize - halfLine) {
                  return const SizedBox.shrink();
                }
                return Text(
                  '${value.round()}',
                  style: const TextStyle(color: kTextSubtle, fontSize: kFontSM),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: kTextGhost),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.5,
            gradient: _zoneGradient(
              minY: minY, maxY: maxY, dangerY: dangerY,
              z1: z1, z2: z2, z3: z3, z4: z4, z5: z5,
              hasAllZones: hasAllZones,
              zone1End: zone1End, zone2Start: zone2Start, zone3Start: zone3Start,
              zone4Start: zone4Start, zone5Start: zone5Start,
            ),
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: const [
                  Color(0x0A44CC55), // Zone 1 green tint at bottom
                  Color(0x0A9CCC20), // Zone 2 chartreuse
                  Color(0x0AFFD000), // Zone 3 yellow
                  Color(0x0AFF6D00), // Zone 4 orange
                  Color(0x0AE84855), // Zone 5 red tint at top
                ],
              ),
            ),
          ),
        ],
      ),
    );

    // Wrap in Stack only when edge indicators are needed
    if (highEdgeLabel == null && lowEdgeLabel == null) return chart;

    return Stack(
      children: [
        chart,
        if (highEdgeLabel != null)
          Positioned(
            top: 9, // inside top reserved space + border
            left: 37,
            right: 44, // clear the right-side Y-axis labels (reservedSize 42)
            child: _ZoneEdgeIndicator(label: highEdgeLabel, color: highEdgeColor ?? kAccent),
          ),
        if (lowEdgeLabel != null)
          Positioned(
            bottom: 23, // above the bottom time-axis labels
            left: 37,
            right: 44, // clear the right-side Y-axis labels (reservedSize 42)
            child: _ZoneEdgeIndicator(label: lowEdgeLabel, color: lowEdgeColor ?? kAccent),
          ),
      ],
    );
  }
}

// ── Workout type selector ──────────────────────────────────────────────────────

class _WorkoutTypeSelector extends StatelessWidget {
  const _WorkoutTypeSelector({required this.provider, this.disabled = false});
  final WorkoutProvider provider;
  final bool disabled;

  static const _types = WorkoutType.values;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.38 : 1.0,
      child: IgnorePointer(
        ignoring: disabled,
        child: Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: _types.asMap().entries.map((e) {
          final idx = e.key;
          final type = e.value;
          final selected = provider.selectedWorkoutType == type;
          return Expanded(
            child: Semantics(
              button: true,
              selected: selected,
              // "Boxing workout, 1 of 6, selected" — gives VoiceOver users a
              // clear sense of how many options exist and where they are in
              // the list. Without this they'd hear six identical-style
              // buttons with no context.
              label: '${type.label} workout, ${idx + 1} of ${_types.length}${selected ? ", selected" : ""}',
              child: GestureDetector(
                onTap: () => provider.setWorkoutType(type),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
                  decoration: BoxDecoration(
                    // kAccent for selected state — matches the units, voice,
                    // and interval pickers in Preferences so the "selected"
                    // affordance reads the same way everywhere.
                    color: selected ? kAccent : Colors.transparent,
                    borderRadius: BorderRadius.horizontal(
                      left: idx == 0 ? const Radius.circular(12) : Radius.zero,
                      right: idx == _types.length - 1 ? const Radius.circular(12) : Radius.zero,
                    ),
                  ),
                  child: ExcludeSemantics(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        WorkoutTypeIcon(
                          type: type,
                          size: 22,
                          color: selected ? Colors.white : kTextLabel,
                        ),
                        const SizedBox(height: 4),
                        Text(type.label,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: selected ? Colors.white : kTextLabel,
                              fontSize: kFontSM,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                            )),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
        ),
      ),
    );
  }
}


// ── Post-workout summary ───────────────────────────────────────────────────────

class _PostWorkoutSummary extends StatelessWidget {
  const _PostWorkoutSummary({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final maxBpm  = provider.summaryMaxBpm;
    final avgBpm  = provider.summaryAvgBpm;
    final dur     = provider.summaryDuration;
    final kcal    = provider.currentKcal;
    final effort  = provider.summaryEffortPct;
    final hist    = provider.summaryHistogram;
    final steps   = provider.currentSteps;
    final dist    = provider.currentDistanceMeters;
    final floors  = provider.currentFloorsClimbed;
    final resp    = provider.currentRespiratoryRate;

    if (maxBpm == null) return const SizedBox.shrink();


    return Container(
      color: kSummaryBg,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _StatChip('max HR',   '${maxBpm.round()}',       'bpm',  kAccent),
              if (avgBpm != null)
                _StatChip('avg HR', '${avgBpm.round()}',       'bpm',  kZone3),
              if (dur != null)
                _StatChip('duration', fmtDuration(dur.inSeconds),             '',     Colors.white70),
              if (kcal != null)
                _StatChip('kcal',   '${kcal.round()}',         '',     kZone2),
              if (effort != null)
                _StatChip('effort', '${effort.round()}',       '%',    kCyan),
            ],
          ),
          if (steps != null || dist != null || (floors != null && floors > 0) || resp != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (steps != null)
                  _StatChip('steps',    fmtSteps(steps), '',    Colors.white70),
                if (dist != null)
                  _StatChip('distance', fmtDist(dist, provider.useImperial), '', kCyan),
                if (floors != null && floors > 0)
                  _StatChip('floors',   '${floors.round()}', '', kZone2),
                if (resp != null)
                  _StatChip('resp',     '${resp.round()}', 'br/min', kCyan),
              ],
            ),
          ],
          if (provider.currentAscentMeters > 0) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _StatChip('ascent',
                    fmtElevation(provider.currentAscentMeters, provider.useImperial),
                    '', kZone2),
                _StatChip('vert work',
                    provider.currentElevationWorkKJ.toStringAsFixed(0), 'kJ', kCyan),
                _StatChip('climb', '${provider.elevationKcal.round()}', 'kcal', kZone3),
              ],
            ),
          ],
          if (hist != null && hist.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 70,
              child: _HrHistogram(histogram: hist, provider: provider),
            ),
          ],
          const SizedBox(height: 8),
          _ZoneTimeLine(provider: provider),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip(this.label, this.value, this.unit, this.color);
  final String label, value, unit;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label,
          style: const TextStyle(color: kTextSubtle, fontSize: 9, letterSpacing: 0.3)),
      const SizedBox(height: 2),
      RichText(
        text: TextSpan(children: [
          TextSpan(text: value,
              style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w200)),
          if (unit.isNotEmpty)
            TextSpan(text: ' $unit',
                style: TextStyle(color: color.withAlpha(0xAA), fontSize: 9)),
        ]),
      ),
    ],
  );
}

// ── HR histogram (CustomPainter for pixel-level control) ──────────────────────

class _HrHistogram extends StatelessWidget {
  const _HrHistogram({required this.histogram, required this.provider});
  final Map<int, double> histogram;
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _HistogramPainter(histogram: histogram, provider: provider),
  );
}

class _HistogramPainter extends CustomPainter {
  const _HistogramPainter({required this.histogram, required this.provider});
  final Map<int, double> histogram;
  final WorkoutProvider provider;

  Color _colorFor(double bpm) => hrZoneColor(
        bpm,
        zone1End: provider.zone1End,
        zone2Start: provider.zone2Start,
        zone3Start: provider.zone3Start,
        zone4Start: provider.zone4Start,
        zone5Start: provider.zone5Start,
        dangerFallback: provider.dangerZoneThreshold,
      );

  @override
  void paint(Canvas canvas, Size size) {
    if (histogram.isEmpty) return;
    final keys   = histogram.keys.toList()..sort();
    final bpmMin = keys.first;
    final bpmMax = keys.last;
    final range  = (bpmMax - bpmMin + 1).toDouble();
    final secsMax = histogram.values.reduce(max);
    final barW   = size.width / range;

    for (final e in histogram.entries) {
      final x  = (e.key - bpmMin) * barW;
      final h  = (e.value / secsMax) * size.height;
      canvas.drawRect(
        Rect.fromLTWH(x, size.height - h, max(barW, 1.0), h),
        Paint()..color = _colorFor(e.key.toDouble()),
      );
    }

    // Subtle axis line at bottom
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()..color = kTextGhost..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter old) =>
      old.histogram != histogram;
}
