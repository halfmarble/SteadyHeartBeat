part of 'home_screen.dart';

/// Home — the workout-type selector and the post-workout summary (stat chips
/// and the 1-BPM-resolution HR histogram).
///
/// `part` of home_screen.dart (see home_live_view.dart for why).

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
              _StatChip('max HR',   '${maxBpm.round()}',       'bpm',  kAccent, infoKey: 'maxHr'),
              if (avgBpm != null)
                _StatChip('avg HR', '${avgBpm.round()}',       'bpm',  kZone3, infoKey: 'avgHr'),
              if (dur != null)
                _StatChip('duration', fmtDuration(dur.inSeconds),             '',     Colors.white70),
              if (kcal != null)
                _StatChip('kcal',   '${kcal.round()}',         '',     kZone2, infoKey: 'kcal'),
              if (effort != null)
                _StatChip('effort', '${effort.round()}',       '%',    kCyan, infoKey: 'effort'),
            ],
          ),
          // Activity row — elevation always shown; steps/floors/breaths when present.
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (steps != null)
                _StatChip('steps', fmtSteps(steps), '', Colors.white70),
              _StatChip('elevation',
                  fmtElevation(provider.currentAscentMeters, provider.useImperial),
                  '', kZone2),
              if (floors != null && floors > 0)
                _StatChip('floors', '${floors.round()}', '', kZone2),
              if (resp != null)
                _StatChip('breaths', '${resp.round()}', 'br/min', kCyan),
            ],
          ),
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
  const _StatChip(this.label, this.value, this.unit, this.color, {this.infoKey});
  final String label, value, unit;
  final Color color;
  // When set, the chip gains a small ⓘ next to its label and becomes tappable,
  // opening the metric explainer (plain-language meaning + cited sources). Null
  // chips (duration, steps, ascent, …) stay plain, non-tappable.
  final String? infoKey;

  @override
  Widget build(BuildContext context) {
    final chip = Column(
      mainAxisSize: MainAxisSize.min,
      // Centers the drawn chip when the ConstrainedBox below pads the column
      // out to the 44pt tap minimum; no-op when the chip is taller than that.
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    color: kTextSubtle, fontSize: 9, letterSpacing: 0.3)),
            if (infoKey != null) ...[
              const SizedBox(width: 3),
              const Icon(CupertinoIcons.info_circle, size: 14, color: Colors.white),
            ],
          ],
        ),
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
    if (infoKey == null) return chip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final p = context.read<WorkoutProvider>();
        showMetricExplainer(context, infoKey!,
            age: p.healthAge,
            female: p.effectiveSex == 'female',
            value: double.tryParse(value));
      },
      // Invisible hit-area extension: the drawn chip stays its size, but the
      // opaque tap region grows to the 44pt HIG minimum. A ConstrainedBox, NOT
      // a Container with alignment — an aligned Container expands to fill any
      // bounded constraint (inside a Wrap that means the whole run width, one
      // chip per line).
      child: ConstrainedBox(
        constraints: const BoxConstraints(
            minWidth: kMinTapTarget, minHeight: kMinTapTarget),
        child: chip,
      ),
    );
  }
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
    // All-zero bins would make h below 0/0 = NaN and silently draw nothing.
    if (secsMax <= 0) return;
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
