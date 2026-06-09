import 'dart:math' show max;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show SystemChrome, DeviceOrientation;
import 'package:provider/provider.dart';
import '../services/session_storage_service.dart';
import '../providers/workout_provider.dart';
import '../constants.dart';
import '../utils.dart';
import 'home_screen.dart' show BpmChart;

// ── Sessions screen ───────────────────────────────────────────────────────────

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<Map<String, dynamic>>? _sessions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await SessionStorageService.loadAll();
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _delete(Map<String, dynamic> session) async {
    final id = session['id'] as String?;
    if (id == null) return;
    await SessionStorageService.delete(id);
    if (mounted) setState(() => _sessions?.remove(session));
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('Delete session?'),
        content: const Text('This cannot be undone.'),
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
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions',
            style: TextStyle(
                fontSize: kFontLG,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.pop(context),
          child: const Icon(CupertinoIcons.back, color: kAccent),
        ),
      ),
      body: _sessions == null
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : _sessions!.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: kSpaceXXL),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.chart_bar,
                            color: kTextGhost, size: kIconLG),
                        SizedBox(height: kSpaceXXL),
                        Text('No sessions yet.',
                            style: TextStyle(
                                color: kTextSubtle, fontSize: kFontXL)),
                        SizedBox(height: kSpaceSM),
                        Text(
                          'Go back to the home screen, put in your AirPods, and tap Start. Your finished workouts will show up here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: kTextFaint, fontSize: kFontMD, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                      vertical: kSpaceXXL, horizontal: kSpaceXXL),
                  itemCount: _sessions!.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: kSpaceLG),
                  itemBuilder: (context, i) {
                    final session = _sessions![i];
                    final useImperial = context.read<WorkoutProvider>().useImperial;
                    return Dismissible(
                      key: ValueKey(session['id'] ?? i),
                      direction: DismissDirection.horizontal,
                      confirmDismiss: (dir) async {
                        if (dir == DismissDirection.startToEnd) {
                          // Swipe right → open the full chart; snap the card
                          // back (don't dismiss it).
                          _showSessionChart(context, session);
                          return false;
                        }
                        // Swipe left → delete.
                        return _confirmDelete(context);
                      },
                      onDismissed: (_) => _delete(session),
                      // Swipe-right reveal (left side): "view chart" affordance.
                      background: Container(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.only(left: kSpaceMax),
                        decoration: BoxDecoration(
                          color: kCyan.withAlpha(kAlphaLow),
                          borderRadius: BorderRadius.circular(kCardRadius),
                        ),
                        child: const Icon(CupertinoIcons.chart_bar_alt_fill,
                            color: kCyan, size: kIconSM),
                      ),
                      // Swipe-left reveal (right side): delete affordance.
                      secondaryBackground: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: kSpaceMax),
                        decoration: BoxDecoration(
                          color: kAccent.withAlpha(kAlphaLow),
                          borderRadius:
                              BorderRadius.circular(kCardRadius),
                        ),
                        child: const Icon(CupertinoIcons.trash,
                            color: kAccent, size: kIconSM),
                      ),
                      // Open the full chart by swiping the card right OR
                      // double-tapping it; swipe left deletes. (Double-tap, not
                      // single-tap, so a stray touch while scrolling the list
                      // doesn't fling open a dialog.)
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: () => _showSessionChart(context, session),
                        child: _SessionCard(
                          session: session,
                          useImperial: useImperial,
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

IconData _iconFor(WorkoutType type) => switch (type) {
      WorkoutType.boxing  => Icons.sports_mma,
      WorkoutType.cycling => Icons.directions_bike,
      WorkoutType.running => Icons.directions_run,
      WorkoutType.walking => Icons.directions_walk,
      WorkoutType.hiking  => Icons.hiking,
      WorkoutType.other   => Icons.fitness_center,
    };

// ── Session chart viewer (double-tap a session) ───────────────────────────────

WorkoutType _workoutTypeForKey(String key) => switch (key) {
      'boxing'  => WorkoutType.boxing,
      'cycling' => WorkoutType.cycling,
      'running' => WorkoutType.running,
      'walking' => WorkoutType.walking,
      'hiking'  => WorkoutType.hiking,
      _         => WorkoutType.other,
    };

String _fmtSessionDate(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final h = dt.hour, m = dt.minute;
  return '${months[dt.month - 1]} ${dt.day}  '
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// Rebuilds the full-resolution heart-rate chart from a saved session's stored
/// `hrTimeline` and zone snapshot, reusing the live [BpmChart] so the replay
/// looks identical to what the user saw during the workout. Returns null when
/// the session has too few samples to draw a line.
BpmChart? _chartForSession(Map<String, dynamic> session) {
  final raw = session['hrTimeline'] as List?;
  if (raw == null || raw.length < 2) return null;

  final history = <BpmSample>[];
  for (final e in raw) {
    final pair = e as List;
    history.add(BpmSample(
      (pair[0] as num).toDouble(),
      (pair[1] as num).toDouble(),
    ));
  }

  // Moving-average smoothing — must match WorkoutProvider._updateSmoothedBpms
  // exactly (window = kSmoothWindow, lo = i - window~/2, hi = lo + window,
  // both clamped) so the replayed line is identical to the live chart.
  const window = kSmoothWindow;
  final n = history.length;
  final smoothed = <double>[];
  for (int i = 0; i < n; i++) {
    final lo = max(0, i - window ~/ 2);
    final hiRaw = lo + window;
    final hi = hiRaw < n ? hiRaw : n;
    var sum = 0.0;
    for (int j = lo; j < hi; j++) {
      sum += history[j].bpm;
    }
    smoothed.add(sum / (hi - lo));
  }

  int? zone(String k) => (session[k] as num?)?.toInt();
  // Same fallback the histograms use (zone5Start → kDefaultDangerBpm) so the
  // danger line and the bar colour break line up in the replay dialog.
  final danger = zone('zone5Start') ?? kDefaultDangerBpm;

  return BpmChart(
    history: history,
    smoothedBpms: smoothed,
    dangerThreshold: danger,
    zone1End: zone('zone1End'),
    zone2Start: zone('zone2Start'),
    zone3Start: zone('zone3Start'),
    zone4Start: zone('zone4Start'),
    zone5Start: zone('zone5Start'),
    enableScrubber: true, // landscape-only; gated inside BpmChart
  );
}

void _showSessionChart(BuildContext context, Map<String, dynamic> session) {
  final chart = _chartForSession(session);
  if (chart == null) return;

  final useImperial = context.read<WorkoutProvider>().useImperial;
  final type = _workoutTypeForKey(session['workoutType'] as String? ?? 'other');
  final dist = (session['distanceMeters'] as num?)?.toDouble();
  final distLabel = dist != null ? fmtDist(dist, useImperial) : null;
  DateTime? end;
  final endRaw = session['endTime'] as String?;
  if (endRaw != null) {
    try {
      end = DateTime.parse(endRaw);
    } catch (_) {}
  }

  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Session chart',
    barrierColor: Colors.black87,
    transitionDuration: const Duration(milliseconds: 260),
    // Fade + slight slide; the reverse plays on close (swipe-up or tap-outside)
    // so the chart eases upward and fades out instead of vanishing. begin offset
    // is above zero so the close drifts UP, matching the swipe-up gesture.
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, -0.08), end: Offset.zero)
              .animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (ctx, _, _) => Dialog(
      // Transparent so the Dialog only supplies bounded layout constraints (the
      // Expanded chart needs them); the visible card is the Material below,
      // which is what the swipe-to-dismiss actually translates and fades.
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(kSpaceLG),
      // Swipe up on the header/summary to close (the chart itself is reserved
      // for scrubbing). Tapping the barrier outside dismisses too.
      child: Material(
        color: kBackground,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kCardRadius)),
        child: _SessionChartView(
          chart: chart,
          type: type,
          distLabel: distLabel,
          end: end,
          session: session,
          useImperial: useImperial,
        ),
      ),
    ),
  );
}

// ── Session chart dialog body ─────────────────────────────────────────────────

/// The full-chart dialog content: header (with an opt-in expand button that
/// rotates to fullscreen landscape), the chart, and the summary. Orientation is
/// forced only when the user taps expand, and always restored when the dialog
/// leaves the tree (dispose), regardless of how it was dismissed.
class _SessionChartView extends StatefulWidget {
  const _SessionChartView({
    required this.chart,
    required this.type,
    required this.distLabel,
    required this.end,
    required this.session,
    required this.useImperial,
  });
  final BpmChart chart;
  final WorkoutType type;
  final String? distLabel;
  final DateTime? end;
  final Map<String, dynamic> session;
  final bool useImperial;

  @override
  State<_SessionChartView> createState() => _SessionChartViewState();
}

class _SessionChartViewState extends State<_SessionChartView>
    with SingleTickerProviderStateMixin {
  // Swipe-up-to-dismiss state. The drag handles live on the header and summary
  // ONLY — the chart is left free so fl_chart receives the scrub gesture
  // (a full-card drag wrapper would otherwise swallow it).
  double _dy = 0; // current offset; <= 0 (upward only)
  bool _closing = false;
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  Animation<double>? _anim;

  @override
  void dispose() {
    // Always hand rotation control back when the dialog closes — covers every
    // dismiss path (swipe-up, barrier tap, back gesture).
    SystemChrome.setPreferredOrientations(const []);
    _ctrl.dispose();
    super.dispose();
  }

  double get _height => context.size?.height ?? 600;

  // Force the requested orientation. The button drives this off the *actual*
  // MediaQuery orientation (not an internal flag), so it always produces a
  // visible rotation — to landscape from portrait, back to portrait from
  // landscape — even when the user got to landscape by rotating the phone.
  void _setOrientation({required bool landscape}) {
    SystemChrome.setPreferredOrientations(landscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp]);
  }

  void _animateTo(double target, {bool dismiss = false}) {
    _anim = Tween<double>(begin: _dy, end: target)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut))
      ..addListener(() => setState(() => _dy = _anim!.value));
    _ctrl
      ..reset()
      ..forward().whenComplete(() {
        if (dismiss) Navigator.of(context).maybePop();
      });
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_closing) return;
    setState(() {
      _dy += d.delta.dy;
      if (_dy > 0) _dy = 0; // upward only
    });
  }

  void _onDragEnd(DragEndDetails d) {
    if (_closing) return;
    final v = d.primaryVelocity ?? 0; // negative = upward
    if (v < -400 || _dy < -_height * 0.25) {
      _closing = true;
      _animateTo(-_height - 40, dismiss: true);
    } else {
      _animateTo(0);
    }
  }

  /// Wraps a chrome region (header / summary) as a dismiss handle: swipe it up,
  /// or double-tap it, to close the detail view. The chart between them takes
  /// the same double-tap-to-close (see its own wrapper) but no dismiss-drag, so
  /// the landscape scrubber's drag stays unobstructed.
  Widget _dragHandle(Widget child) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        onDoubleTap: () => Navigator.of(context).maybePop(),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final opacity = (1 + _dy / _height).clamp(0.0, 1.0);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return Opacity(
      opacity: opacity,
      child: Transform.translate(
        offset: Offset(0, _dy),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(kSpaceLG),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header doubles as a swipe-up dismiss handle.
                _dragHandle(Row(
                  children: [
                    Icon(_iconFor(widget.type), size: kIconSM, color: kTextMuted),
                    const SizedBox(width: kSpaceMD),
                    Text(widget.type.label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: kFontLG,
                            fontWeight: FontWeight.w600)),
                    if (widget.distLabel != null) ...[
                      const SizedBox(width: kSpaceMD),
                      Text(widget.distLabel!,
                          style: const TextStyle(
                              color: kCyan,
                              fontSize: kFontLG,
                              fontWeight: FontWeight.w400)),
                    ],
                    const Spacer(),
                    if (widget.end != null)
                      Text(_fmtSessionDate(widget.end!),
                          style: const TextStyle(
                              color: kTextSubtle, fontSize: kFontBase)),
                    const SizedBox(width: kSpaceLG),
                    // Orientation toggle (44px tap target). Reflects the real
                    // orientation: expand→landscape in portrait, collapse→
                    // portrait in landscape — always a visible change.
                    Semantics(
                      button: true,
                      label: isLandscape
                          ? 'Back to portrait'
                          : 'View fullscreen in landscape',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _setOrientation(landscape: !isLandscape),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(
                            isLandscape
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                            size: kIconMD,
                            color: kCyan,
                          ),
                        ),
                      ),
                    ),
                  ],
                )),
                const SizedBox(height: kSpaceMD),
                // Chart — double-tap closes the view (a discrete tap gesture,
                // so it doesn't claim the drag the landscape scrubber needs);
                // no dismiss-DRAG here, which would fight the scrub.
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: () => Navigator.of(context).maybePop(),
                    child: widget.chart,
                  ),
                ),
                const SizedBox(height: kSpaceMD),
                // Summary is also a swipe-up dismiss handle.
                _dragHandle(_SessionSummary(
                    session: widget.session, useImperial: widget.useImperial)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Session card ──────────────────────────────────────────────────────────────

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.useImperial});
  final Map<String, dynamic> session;
  final bool useImperial;

  @override
  Widget build(BuildContext context) {
    final type     = _typeForKey(session['workoutType'] as String? ?? 'other');
    final endTime  = _parseDate(session['endTime'] as String?);
    final durSecs  = (session['durationSeconds'] as num?)?.toInt() ?? 0;
    final maxBpm   = (session['maxBpm']    as num?)?.toDouble();
    final avgBpm   = (session['avgBpm']    as num?)?.toDouble();
    final kcal     = (session['kcal']      as num?)?.toDouble();
    final effort   = (session['effortPct'] as num?)?.toDouble();
    final steps    = (session['steps']     as num?)?.toDouble();
    final dist     = (session['distanceMeters'] as num?)?.toDouble();
    final floors   = (session['floorsClimbed']  as num?)?.toDouble();
    final resp     = (session['respiratoryRate'] as num?)?.toDouble();
    final hist     = _parseHistogram(session['histogram']);
    final zoneSecs = (session['zoneSecs'] as List?)
        ?.map((v) => (v as num).toDouble())
        .toList();

    return Container(
      padding: const EdgeInsets.all(kSpaceXXL),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(kCardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row mirrors the full-chart screen: icon · name · distance
          // (left) · date (right), all on one line. Duration moves into the
          // stats row below. Deletion is swipe-to-delete (Dismissible wrapper).
          Row(
            children: [
              _WorkoutIcon(type: type),
              const SizedBox(width: kSpaceLG),
              Text(type.label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: kFontLG,
                      fontWeight: FontWeight.w600)),
              if (dist != null) ...[
                const SizedBox(width: kSpaceMD),
                Text(fmtDist(dist, useImperial),
                    style: const TextStyle(
                        color: kCyan,
                        fontSize: kFontLG,
                        fontWeight: FontWeight.w400)),
              ],
              const Spacer(),
              if (endTime != null)
                Text(_fmtDate(endTime),
                    style: const TextStyle(
                        color: kTextSubtle, fontSize: kFontBase)),
            ],
          ),
          const SizedBox(height: kSpaceXL),
          // Mini HR histogram on top (the chart-equivalent); stats go below it,
          // mirroring the full-chart screen's chart → stats order.
          if (hist != null && hist.isNotEmpty) ...[
            SizedBox(
              height: 40,
              width: double.infinity,
              child: _MiniHistogram(histogram: hist, session: session),
            ),
            const SizedBox(height: kSpaceMD),
          ],
          // Primary stats — under the histogram
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (maxBpm != null)
                _Chip('max HR', '${maxBpm.round()}', 'bpm', kAccent),
              if (avgBpm != null)
                _Chip('avg HR', '${avgBpm.round()}', 'bpm', kZone3),
              if (durSecs > 0)
                _Chip('duration', fmtDuration(durSecs), '', Colors.white70),
              if (kcal != null)
                _Chip('kcal', '${kcal.round()}', '', kZone2),
              if (effort != null)
                _Chip('effort', '${effort.round()}', '%', kCyan),
            ],
          ),
          // Activity stats (distance lives in the header next to the title)
          if (steps != null ||
              (floors != null && floors > 0) ||
              resp != null) ...[
            const SizedBox(height: kSpaceSM),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (steps != null)
                  _Chip('steps', fmtSteps(steps), '', Colors.white70),
                if (floors != null && floors > 0)
                  _Chip('floors', '${floors.round()}', '', kZone2),
                if (resp != null)
                  _Chip('resp', '${resp.round()}', 'br/min', kCyan),
              ],
            ),
          ],
          // Zone time bar
          if (zoneSecs != null && zoneSecs.any((s) => s > 0)) ...[
            const SizedBox(height: kSpaceLG),
            _ZoneBar(zoneSecs: zoneSecs),
          ],
        ],
      ),
    );
  }

  WorkoutType _typeForKey(String key) => switch (key) {
        'boxing'  => WorkoutType.boxing,
        'cycling' => WorkoutType.cycling,
        'running' => WorkoutType.running,
        'walking' => WorkoutType.walking,
        'hiking'  => WorkoutType.hiking,
        _         => WorkoutType.other,
      };

  DateTime? _parseDate(String? s) {
    if (s == null) return null;
    try { return DateTime.parse(s); } catch (_) { return null; }
  }

  Map<int, double>? _parseHistogram(dynamic raw) {
    if (raw == null) return null;
    try {
      return (raw as Map).map(
          (k, v) => MapEntry(int.parse(k as String), (v as num).toDouble()));
    } catch (_) { return null; }
  }

  String _fmtDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = dt.hour, m = dt.minute;
    return '${months[dt.month - 1]} ${dt.day}  '
        '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }
}

// Post-workout summary rebuilt from a saved session map (stat chips + HR
// histogram + time-in-zones), matching the live summary shown after a workout.
// Reads everything from the session JSON rather than the provider so it works
// for any saved session, not just the one that just ended.
class _SessionSummary extends StatelessWidget {
  const _SessionSummary({required this.session, required this.useImperial});
  final Map<String, dynamic> session;
  final bool useImperial;

  static double? _d(dynamic v) => (v as num?)?.toDouble();

  @override
  Widget build(BuildContext context) {
    final maxBpm  = _d(session['maxBpm']);
    final avgBpm  = _d(session['avgBpm']);
    final durSecs = (session['durationSeconds'] as num?)?.toInt();
    final kcal    = _d(session['kcal']);
    final effort  = _d(session['effortPct']);
    final steps   = _d(session['steps']);
    final floors  = _d(session['floorsClimbed']);
    final resp    = _d(session['respiratoryRate']);
    // Distance is shown in the dialog header (next to the workout label), so it
    // is intentionally omitted from these chips. The HR histogram is omitted
    // too — it duplicates the line chart above; dropping it gives the chart
    // more room.
    final zoneSecs = (session['zoneSecs'] as List?)
        ?.map((v) => (v as num).toDouble())
        .toList();

    if (maxBpm == null) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _Chip('max HR', '${maxBpm.round()}', 'bpm', kAccent),
            if (avgBpm != null)
              _Chip('avg HR', '${avgBpm.round()}', 'bpm', kZone3),
            if (durSecs != null)
              _Chip('duration', fmtDuration(durSecs), '', Colors.white70),
            if (kcal != null)
              _Chip('kcal', '${kcal.round()}', '', kZone2),
            if (effort != null)
              _Chip('effort', '${effort.round()}', '%', kCyan),
          ],
        ),
        if (steps != null || (floors != null && floors > 0) || resp != null) ...[
          const SizedBox(height: kSpaceSM),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (steps != null)
                _Chip('steps', fmtSteps(steps), '', Colors.white70),
              if (floors != null && floors > 0)
                _Chip('floors', '${floors.round()}', '', kZone2),
              if (resp != null)
                _Chip('resp', '${resp.round()}', 'br/min', kCyan),
            ],
          ),
        ],
        if (zoneSecs != null && zoneSecs.any((s) => s > 0)) ...[
          const SizedBox(height: kSpaceMD),
          _ZoneBar(zoneSecs: zoneSecs),
        ],
      ],
    );
  }
}

// ── Workout icon (boxing = mirrored pair, others = single icon) ───────────────

class _WorkoutIcon extends StatelessWidget {
  const _WorkoutIcon({required this.type});
  final WorkoutType type;

  @override
  Widget build(BuildContext context) {
    if (type == WorkoutType.boxing) {
      return SizedBox(
        width: 38, height: kIconMD,
        child: Stack(children: [
          Positioned(left: 0, top: 0,
            child: const Icon(Icons.sports_mma, size: kIconMD, color: kTextMuted)),
          Positioned(right: 0, top: 0,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(-1, 1, 1),
              child: const Icon(Icons.sports_mma, size: kIconMD, color: kTextMuted),
            )),
        ]),
      );
    }
    return Icon(_iconFor(type), size: kIconMD, color: kTextMuted);
  }
}

// ── Stat chip ─────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.value, this.unit, this.color);
  final String label, value, unit;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(
                  color: kTextDim,
                  fontSize: kFontXS,
                  letterSpacing: 0.3)),
          const SizedBox(height: kSpaceXS),
          RichText(
            text: TextSpan(children: [
              TextSpan(
                  text: value,
                  style: TextStyle(
                      color: color,
                      fontSize: kFontStat,
                      fontWeight: FontWeight.w200)),
              if (unit.isNotEmpty)
                TextSpan(
                    text: ' $unit',
                    style: TextStyle(
                        color: color.withAlpha(kAlphaMuted),
                        fontSize: kFontXS)),
            ]),
          ),
        ],
      );
}

// ── Zone time bar ─────────────────────────────────────────────────────────────

class _ZoneBar extends StatelessWidget {
  const _ZoneBar({required this.zoneSecs});
  final List<double> zoneSecs;

  static const _colors = kZoneColors;
  static const _labels = ['<50', 'Z1', 'Z2', 'Z3', 'Z4', 'Z5'];

  @override
  Widget build(BuildContext context) {
    final total = zoneSecs.fold(0.0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();

    // One centered label: "Z1 109m · Z2 10m · Z3 20s". Per-zone colours via
    // TextSpans; the " · " separator is inserted only BETWEEN rendered zones
    // (not before the first), so a zero-time lowest zone leaves no leading dot.
    final spans = <InlineSpan>[];
    for (int i = 0; i < zoneSecs.length; i++) {
      if (zoneSecs[i] <= 0) continue;
      if (spans.isNotEmpty) {
        spans.add(const TextSpan(
          text: '  ·  ',
          style: TextStyle(color: kTextGhost, fontSize: kFontSM),
        ));
      }
      spans.add(TextSpan(
        text: '${_labels[i]} ${_fmtSecs(zoneSecs[i])}',
        style: TextStyle(
            color: _colors[i].withAlpha(kAlphaHigh), fontSize: kFontSM),
      ));
    }
    if (spans.isEmpty) return const SizedBox.shrink();

    // Full width so textAlign.center actually centers within the card — the
    // session card's Column is crossAxisAlignment.start, which would otherwise
    // size this to its content and pin it to the left.
    return SizedBox(
      width: double.infinity,
      child: Text.rich(
        TextSpan(children: spans),
        textAlign: TextAlign.center,
      ),
    );
  }

  String _fmtSecs(double s) =>
      s < 60 ? '${s.round()}s' : '${(s / 60).round()}m';
}

// ── Mini HR histogram ─────────────────────────────────────────────────────────

class _MiniHistogram extends StatelessWidget {
  const _MiniHistogram({required this.histogram, required this.session});
  final Map<int, double> histogram;
  final Map<String, dynamic> session;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _MiniHistPainter(histogram: histogram, session: session),
      );
}

class _MiniHistPainter extends CustomPainter {
  const _MiniHistPainter({required this.histogram, required this.session});
  final Map<int, double> histogram;
  final Map<String, dynamic> session;

  Color _colorFor(int bpm) {
    int? n(String v) => (session[v] as num?)?.toInt();
    return hrZoneColor(
      bpm.toDouble(),
      zone1End: n('zone1End'),
      zone2Start: n('zone2Start'),
      zone3Start: n('zone3Start'),
      zone4Start: n('zone4Start'),
      zone5Start: n('zone5Start'),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (histogram.isEmpty) return;
    final keys    = histogram.keys.toList()..sort();
    final bpmMin  = keys.first;
    final bpmMax  = keys.last;
    final range   = (bpmMax - bpmMin + 1).toDouble();
    final secsMax = histogram.values.reduce(max);
    final barW    = size.width / range;

    for (final e in histogram.entries) {
      final x = (e.key - bpmMin) * barW;
      final h = (e.value / secsMax) * size.height;
      canvas.drawRect(
        Rect.fromLTWH(x, size.height - h, max(barW, 1.0), h),
        Paint()..color = _colorFor(e.key),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MiniHistPainter old) => false;
}
