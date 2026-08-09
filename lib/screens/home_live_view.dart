part of 'home_screen.dart';

/// Home — the running-workout area: the chart, the drifting BPM overlay, the
/// subtitle and the zone-time line.
///
/// A `part` of home_screen.dart, not a separate library: these are private
/// widgets of that screen, and `part` splits the 2k-line file without turning
/// them into public API. Imports live in the parent file.
///
/// Everything here sits under the home screen's single live-area Consumer,
/// which is deliberate — every widget below consumes per-sample data, so a
/// finer-grained split would remove no rebuilds.

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
        final hasSubMetrics = !isError && (steps != null || (floors != null && floors > 0));
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
                      if (steps != null && floors != null && floors > 0)
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
