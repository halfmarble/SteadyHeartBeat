part of 'home_screen.dart';

/// Home — the idle (pre-workout) area: AirPods status, the round banner, the
/// readiness metric row and the error card.
///
/// `part` of home_screen.dart (see home_live_view.dart for why).
///
/// The readiness metrics here are the tap targets that open the ⓘ explainer
/// (label) and the Plus Trends hub (value) — two distinct affordances on one
/// row; keep them distinguishable.

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
    // During a module-driven phase (e.g. an HR-gated warm-up) the module
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

    // Age label: "manual" when overridden, amber when the auto value is stale,
    // otherwise tinted to match the value's own colour so the freshness line
    // reads as part of the same metric.
    String ageLabel(bool manual, DateTime? date) =>
        manual ? 'manual' : _age(date);
    Color ageTint(bool manual, bool stale, Color valueColor) =>
        manual ? kTextMuted : (stale ? kZone3 : valueColor);

    // Age for grading HRV/VO₂max against age-appropriate norms (see
    // health_norms.dart). Falls back to a mid-adult reference when DOB/age is
    // unknown — same spirit as the old single fixed thresholds.
    final normAge = provider.healthAge ?? 45;
    final normFemale = provider.effectiveSex == 'female';

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
        prefix: '',
        value: ms.round().toString(),
        unit: 'ms',
        color: c,
        age: ageLabel(manual, provider.recentHrvDate),
        ageColor: ageTint(manual, provider.hrvStale, c),
        infoKey: overnight ? 'bedHrv' : 'restingHrv',
        // Tap the HRV value → daily-trends hub (the overnight HRV history is
        // shown regardless of whether today's reading is the bed or resting
        // value). Paid build only; the free core has no trends entry point.
        onValueTap: provider.plus.trendsVisible
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
        prefix: '',
        value: bpm.round().toString(),
        unit: 'bpm',
        color: c,
        age: ageLabel(manual, provider.recentRestingHrDate),
        ageColor: ageTint(manual, provider.restingHrStale, c),
        infoKey: overnight ? 'bedHr' : 'restingHr',
        onValueTap: provider.plus.trendsVisible
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
        prefix: '',
        value: v.round().toString(),
        unit: 'ml/kg/min',
        color: c,
        age: ageLabel(manual, provider.recentVo2MaxDate),
        ageColor: ageTint(manual, provider.vo2Stale, c),
        infoKey: 'vo2max',
        onValueTap: provider.plus.trendsVisible
            ? () => provider.plus.openTrends(context, 'vo2max')
            : null,
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
  // Tapping the value opens the metric's daily-trends chart via the plus plug
  // point — owner builds only (trendsVisible). Null = value not tappable.
  final VoidCallback? onValueTap;

  @override
  Widget build(BuildContext context) {
    const labelStyle =
        TextStyle(color: kTextDim, fontSize: kFontSM, letterSpacing: 0.4);
    // The ⓘ opens the metric's explainer; it's a small, distinct tap target
    // nested inside the larger cell below (bright white, larger — a clear "tap
    // for info & sources" affordance; the explainer carries the citations).
    final Widget? infoIcon = infoKey == null
        ? null
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              // Pass the user's age/sex + the displayed value so the explainer
              // can plot it on the matched expected-range gauge.
              final p = context.read<WorkoutProvider>();
              showMetricExplainer(context, infoKey!,
                  age: p.healthAge,
                  female: p.effectiveSex == 'female',
                  value: double.tryParse(value));
            },
            child: const Padding(
              // (kMinTapTarget - 18) / 2 vertically: the 18pt glyph plus this
              // invisible padding meets the 44pt HIG tap minimum.
              padding: EdgeInsets.symmetric(vertical: 13, horizontal: 14),
              child: Icon(CupertinoIcons.info_circle,
                  size: 18, color: Colors.white),
            ),
          );
    final Widget valueText = RichText(
      text: TextSpan(children: [
        if (prefix.isNotEmpty)
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
    // The whole cell — label, value, and the freshness line beneath — is one
    // big, easy-to-hit target that opens the metric's daily-trends chart. The ⓘ
    // keeps its own nested tap for the explainer; a chart glyph by the value
    // signals the cell is tappable.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onValueTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (infoIcon != null) ...[
              infoIcon,
              const SizedBox(height: 3),
            ],
            Text(label, style: labelStyle),
            const SizedBox(height: 4),
            if (onValueTap == null)
              valueText
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  valueText,
                  const SizedBox(width: 4),
                  Icon(Icons.show_chart, size: 13, color: color.withAlpha(0xAA)),
                ],
              ),
            if (age.isNotEmpty)
              Text(age, style: TextStyle(color: ageColor, fontSize: kFontSM)),
          ],
        ),
      ),
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
