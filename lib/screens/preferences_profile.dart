part of 'preferences_screen.dart';

/// Preferences — the wheel-picker plumbing and the personal-profile sections
/// (age, sex, resting metrics, weight, about).
///
/// `part` of preferences_screen.dart (see preferences_sections.dart for why).
/// Values entered here are personal health data: they belong in the
/// backup-excluded HealthProfileStore, never in shared_preferences.

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
