import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/workout_provider.dart';
import '../services/health_import_service.dart';
import '../constants.dart';
import '../utils.dart';
import '../widgets/workout_type_icon.dart';
import '../widgets/app_chrome.dart';

/// Imports past workouts from Apple Health as local sessions — the recovery
/// path when session files are lost from this device (every finished workout
/// the app saves to Apple Health carries the HR samples to rebuild one), and
/// a way to pull in Apple Watch workouts.
///
/// Workouts shorter than an adjustable threshold (default 15 min) are hidden;
/// the rest are listed with type, date, and duration, each individually
/// tickable. "Import Selected Sessions" rebuilds and saves the ticked ones.
class ImportHealthScreen extends StatefulWidget {
  const ImportHealthScreen({super.key});

  @override
  State<ImportHealthScreen> createState() => _ImportHealthScreenState();
}

class _ImportHealthScreenState extends State<ImportHealthScreen> {
  static const _minDurationPrefKey = 'importMinDurationMins';
  static const _defaultMinMins = 15;

  List<HealthWorkout>? _all; // null = loading
  bool _denied = false;
  int _minMins = _defaultMinMins;
  // Selection keyed by the workout's end time (epoch seconds) — stable across
  // re-filters, and the same key used to detect already-saved sessions.
  final Set<int> _selected = {};
  Set<int> _existing = {};
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static int _key(HealthWorkout w) => w.end.millisecondsSinceEpoch ~/ 1000;

  bool _isSaved(HealthWorkout w) => _existing.contains(_key(w));

  List<HealthWorkout> get _visible => (_all ?? const [])
      .where((w) => w.durationSeconds >= _minMins * 60)
      .toList();

  Future<void> _load() async {
    final provider = context.read<WorkoutProvider>();
    final prefs = await SharedPreferences.getInstance();
    final savedMin = prefs.getInt(_minDurationPrefKey) ?? _defaultMinMins;
    final existing = await provider.existingSessionEndEpochs();
    final workouts = await provider.listHealthWorkouts();
    if (!mounted) return;
    setState(() {
      _minMins = savedMin;
      _existing = existing;
      _denied = workouts == null;
      _all = workouts ?? const [];
      // Start with every importable (visible, not already saved) workout
      // ticked — this is a recovery flow, so "bring back everything" is the
      // common case; untick to exclude.
      _selected
        ..clear()
        ..addAll(_visible.where((w) => !_isSaved(w)).map(_key));
    });
  }

  void _setMinMins(int mins) {
    setState(() => _minMins = mins);
    SharedPreferences.getInstance()
        .then((p) => p.setInt(_minDurationPrefKey, mins));
  }

  Future<void> _import() async {
    final toImport =
        _visible.where((w) => _selected.contains(_key(w)) && !_isSaved(w)).toList();
    if (toImport.isEmpty) return;
    setState(() => _importing = true);
    final provider = context.read<WorkoutProvider>();
    final (imported, skipped) = await provider.importHealthWorkouts(toImport);
    final refreshed = await provider.existingSessionEndEpochs();
    if (!mounted) return;
    setState(() {
      _importing = false;
      _existing = refreshed;
      _selected.removeWhere(refreshed.contains);
    });
    final msg = StringBuffer(
        imported == 1 ? 'Imported 1 session.' : 'Imported $imported sessions.');
    if (skipped > 0) {
      msg.write(skipped == 1
          ? ' 1 workout had no heart-rate data and was skipped.'
          : ' $skipped workouts had no heart-rate data and were skipped.');
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg.toString())));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: appBarTitle('Import from Apple Health'),
        leading: backButton(context),
      ),
      body: _all == null
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : _denied
              ? const _CenteredHint(
                  icon: CupertinoIcons.heart_slash,
                  title: 'Health access denied.',
                  detail:
                      'Open Settings → Privacy & Security → Health → SteadyHeartBeat '
                      'and allow reading Workouts and Heart Rate, then come back.',
                )
              : _buildList(),
      bottomNavigationBar: _all == null || _denied ? null : _buildImportBar(),
    );
  }

  Widget _buildList() {
    final visible = _visible;
    final selectable = visible.where((w) => !_isSaved(w)).toList();
    final allTicked = selectable.isNotEmpty &&
        selectable.every((w) => _selected.contains(_key(w)));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kSpaceXXL, kSpaceLG, kSpaceXXL, 0),
          child: _MinDurationControl(minMins: _minMins, onChanged: _setMinMins),
        ),
        if (visible.isEmpty)
          const Expanded(
            child: _CenteredHint(
              icon: CupertinoIcons.chart_bar,
              title: 'No workouts found.',
              detail:
                  'No Apple Health workouts are longer than the minimum above. '
                  'Lower it to see shorter workouts — or, if the list should not '
                  'be empty, check that SteadyHeartBeat may read Workouts in '
                  'Settings → Privacy & Security → Health.',
            ),
          )
        else ...[
          // Select-all header for the visible, not-yet-saved workouts.
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: kSpaceXXL, vertical: kSpaceSM),
            child: Row(
              children: [
                Text(
                  visible.length == 1
                      ? '1 workout'
                      : '${visible.length} workouts',
                  style: const TextStyle(color: kTextSubtle, fontSize: kFontBase),
                ),
                const Spacer(),
                if (selectable.isNotEmpty)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _importing
                        ? null
                        : () => setState(() {
                              if (allTicked) {
                                _selected
                                    .removeAll(selectable.map(_key));
                              } else {
                                _selected.addAll(selectable.map(_key));
                              }
                            }),
                    child: Text(allTicked ? 'Select none' : 'Select all',
                        style:
                            const TextStyle(color: kAccent, fontSize: kFontBase)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                  kSpaceXXL, 0, kSpaceXXL, kSpaceXXL),
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(height: kSpaceSM),
              itemBuilder: (context, i) {
                final w = visible[i];
                final saved = _isSaved(w);
                final ticked = saved || _selected.contains(_key(w));
                return _WorkoutRow(
                  workout: w,
                  saved: saved,
                  ticked: ticked,
                  enabled: !saved && !_importing,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(_key(w));
                    } else {
                      _selected.remove(_key(w));
                    }
                  }),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildImportBar() {
    final count = _visible
        .where((w) => _selected.contains(_key(w)) && !_isSaved(w))
        .length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            kSpaceXXL, kSpaceMD, kSpaceXXL, kSpaceLG),
        child: SizedBox(
          height: 44,
          child: FilledButton(
            onPressed: (count == 0 || _importing) ? null : _import,
            style: FilledButton.styleFrom(
              backgroundColor: kSurface,
              foregroundColor: kAccent,
              side: BorderSide(
                  color: (count == 0 || _importing) ? kTextDim : kAccent),
              disabledBackgroundColor: kSurface,
              disabledForegroundColor: kTextDim,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: _importing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  )
                : Text(count == 0
                    ? 'Import Selected Sessions'
                    : 'Import Selected Sessions ($count)'),
          ),
        ),
      ),
    );
  }
}

// ── Minimum-duration control ──────────────────────────────────────────────────

class _MinDurationControl extends StatelessWidget {
  const _MinDurationControl({required this.minMins, required this.onChanged});
  final int minMins;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: kSpaceXL, vertical: kSpaceMD),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(kCardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Hide workouts shorter than',
                  style: TextStyle(color: kTextSubtle, fontSize: kFontBase)),
              const Spacer(),
              Text(minMins == 0 ? 'off' : '$minMins min',
                  style: const TextStyle(
                      color: kAccent,
                      fontSize: kFontBase,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          Slider(
            value: minMins.toDouble(),
            min: 0,
            max: 60,
            divisions: 12, // 5-minute steps
            activeColor: kAccent,
            inactiveColor: kTextGhost,
            onChanged: (v) => onChanged(v.round()),
          ),
        ],
      ),
    );
  }
}

// ── One workout row ───────────────────────────────────────────────────────────

class _WorkoutRow extends StatelessWidget {
  const _WorkoutRow({
    required this.workout,
    required this.saved,
    required this.ticked,
    required this.enabled,
    required this.onChanged,
  });
  final HealthWorkout workout;
  final bool saved;
  final bool ticked;
  final bool enabled;
  final ValueChanged<bool?> onChanged;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _fmtDate(DateTime dt) {
    final now = DateTime.now();
    final year = dt.year == now.year ? '' : ' ${dt.year}';
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${_months[dt.month - 1]} ${dt.day}$year  $h:$m';
  }

  WorkoutType _typeForKey(String key) => switch (key) {
        'boxing'  => WorkoutType.boxing,
        'cycling' => WorkoutType.cycling,
        'running' => WorkoutType.running,
        'walking' => WorkoutType.walking,
        'hiking'  => WorkoutType.hiking,
        _         => WorkoutType.other,
      };

  @override
  Widget build(BuildContext context) {
    final type = _typeForKey(workout.type);
    final dim = saved || !enabled;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => onChanged(!ticked) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: kSpaceLG, vertical: kSpaceMD),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(kCardRadius),
        ),
        child: Row(
          children: [
            Checkbox(
              value: ticked,
              onChanged: enabled ? onChanged : null,
              activeColor: kAccent,
              checkColor: Colors.white,
              side: const BorderSide(color: kTextDim),
            ),
            WorkoutTypeIcon(
                type: type,
                size: kIconSM,
                color: dim ? kTextDim : kTextMuted),
            const SizedBox(width: kSpaceMD),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(type.label,
                          style: TextStyle(
                              color: dim ? kTextDim : Colors.white,
                              fontSize: kFontMD,
                              fontWeight: FontWeight.w600)),
                      if (saved) ...[
                        const SizedBox(width: kSpaceMD),
                        const Text('already saved',
                            style: TextStyle(
                                color: kTextDim, fontSize: kFontCaption)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_fmtDate(workout.start)}  ·  ${workout.source}',
                    style: const TextStyle(
                        color: kTextSubtle, fontSize: kFontCaption),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: kSpaceMD),
            Text(fmtDuration(workout.durationSeconds.round()),
                style: TextStyle(
                    color: dim ? kTextDim : kCyan,
                    fontSize: kFontMD,
                    fontWeight: FontWeight.w400)),
          ],
        ),
      ),
    );
  }
}

// ── Centered icon + message hint (denied / empty states) ─────────────────────

class _CenteredHint extends StatelessWidget {
  const _CenteredHint(
      {required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kSpaceXXL),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: kTextGhost, size: kIconLG),
            const SizedBox(height: kSpaceXXL),
            Text(title,
                style: const TextStyle(color: kTextSubtle, fontSize: kFontXL)),
            const SizedBox(height: kSpaceSM),
            Text(detail,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextFaint, fontSize: kFontMD, height: 1.4)),
          ],
        ),
      ),
    );
  }
}
