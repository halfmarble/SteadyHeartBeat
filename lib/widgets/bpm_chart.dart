import 'dart:math' show max, min;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../providers/workout_provider.dart' show BpmSample, WorkoutProvider;
import '../constants.dart';
import '../utils.dart';

// Last sample index touched while scrubbing the workout/session HR chart, so a
// drag ticks once per sample (not every frame). Library-private: one chart is
// scrubbed at a time.
int? _workoutScrubIdx;

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
                // Light tick as the scrub crosses to a new sample (gated on the
                // chart-haptics preference). Built-in touch still drives the
                // tooltip; this callback only observes.
                touchCallback: (event, resp) {
                  final spots = resp?.lineBarSpots;
                  if (spots == null || spots.isEmpty) {
                    _workoutScrubIdx = null;
                    return;
                  }
                  final idx = spots.first.spotIndex;
                  if (idx != _workoutScrubIdx) {
                    _workoutScrubIdx = idx;
                    if (context.read<WorkoutProvider>().chartHaptics) {
                      HapticFeedback.lightImpact();
                    }
                  }
                },
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
              getTitlesWidget: (value, _) {
                // Only label true interval ticks. fl_chart also emits a label at
                // the axis max; when the duration isn't a clean multiple of the
                // interval, that edge label overprints the last round tick (e.g.
                // "122m" smeared over "120m"). The exact length is in the header.
                final r = value % labelXInterval;
                if (r >= 1 && (labelXInterval - r) >= 1) {
                  return const SizedBox.shrink();
                }
                return Text(
                  '${(value / 60).round()}m',
                  style: const TextStyle(color: kTextSubtle, fontSize: kFontSM),
                );
              },
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
