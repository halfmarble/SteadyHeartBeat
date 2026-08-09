part of 'preferences_screen.dart';

/// Preferences — the announcement, units, voice and Apple Health sections.
///
/// A `part` of preferences_screen.dart rather than its own library: every
/// widget here is a private implementation detail of that screen, and `part`
/// splits the 1.9k-line file without promoting ~18 leading-underscore classes
/// to public API. Imports live in the parent file.

class _WelcomeSection extends StatelessWidget {
  const _WelcomeSection({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
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
                    'Speak a welcome at launch',
                    style: TextStyle(color: kTextBright, fontSize: kFontLG),
                  ),
                ),
                CupertinoSwitch(
                  value: provider.welcomeEnabled,
                  activeTrackColor: kAccent,
                  onChanged: provider.setWelcomeEnabled,
                ),
              ],
            ),
          ),
          const Divider(color: kStopButton, height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              'When you open the app, it greets you in your chosen voice and '
              'reminds you to put in your AirPods.',
              style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Toggles whether finished workouts are written to Apple Health. Mirrors the
/// [_WelcomeSection] layout: a switch row over an explanatory caption.
class _AppleHealthSection extends StatelessWidget {
  const _AppleHealthSection({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
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
                    'Save workouts to Apple Health',
                    style: TextStyle(color: kTextBright, fontSize: kFontLG),
                  ),
                ),
                CupertinoSwitch(
                  value: provider.saveToHealth,
                  activeTrackColor: kAccent,
                  onChanged: provider.setSaveToHealth,
                ),
              ],
            ),
          ),
          const Divider(color: kStopButton, height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              'On: each finished workout is saved to Apple Health, so it counts '
              'toward your Activity rings. Health then follows your iCloud sync '
              'settings, so it may reach your other Apple devices.\n\n'
              'Off: the workout is kept only inside SteadyHeartBeat and never '
              'leaves this iPhone. Heart rate still works the same during the '
              'session — only the saved record changes.',
              style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// The single row on the main Preferences screen that opens
/// [VoicePreferencesScreen]. Shows the currently-selected voice as a hint.
class _VoicePrefsEntry extends StatelessWidget {
  const _VoicePrefsEntry({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final voice = provider.voiceName ?? 'Automatic';
    return Semantics(
      button: true,
      label: 'Voice and announcements. Voice: $voice. Opens speech settings.',
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VoicePreferencesScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ExcludeSemantics(
            child: Row(
              children: [
                const Icon(CupertinoIcons.waveform, size: kIconXS, color: kAccent),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Voice, interval & change alerts',
                    style: TextStyle(color: kTextBright, fontSize: kFontLG),
                  ),
                ),
                Text(voice,
                    style: const TextStyle(color: kTextSubtle, fontSize: kFontBase)),
                const SizedBox(width: 6),
                const Icon(CupertinoIcons.chevron_right, size: kIconXS, color: kTextLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: kTextLabel,
        fontSize: kFontBase,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _UnitsSelector extends StatelessWidget {
  const _UnitsSelector({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final imperial = provider.useImperial;
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _buildOption('Metric', 'm / km', false, imperial, isFirst: true),
          _buildOption('Imperial', 'ft / mi', true, imperial, isFirst: false),
        ],
      ),
    );
  }

  Widget _buildOption(String label, String sub, bool value, bool current, {required bool isFirst}) {
    final selected = current == value;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label units${selected ? ", selected" : ""}',
        child: GestureDetector(
          onTap: () => provider.setUseImperial(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? kAccent : Colors.transparent,
              borderRadius: BorderRadius.horizontal(
                left:  isFirst  ? const Radius.circular(12) : Radius.zero,
                right: !isFirst ? const Radius.circular(12) : Radius.zero,
              ),
            ),
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: selected ? Colors.white : kTextLabel,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          fontSize: kFontLG)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: TextStyle(
                          color: selected ? Colors.white70 : kTextDim,
                          fontSize: kFontCaption)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceSelector extends StatelessWidget {
  const _VoiceSelector({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final name = provider.voiceName ?? 'Automatic (best available)';
    return Semantics(
      button: true,
      label: 'Announce voice, currently $name. Opens the voice picker.',
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VoiceScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ExcludeSemantics(
            child: Row(
              children: [
                const Icon(CupertinoIcons.waveform, size: kIconXS, color: kAccent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(color: kTextBright, fontSize: kFontLG),
                  ),
                ),
                const Icon(CupertinoIcons.chevron_right, size: kIconXS, color: kTextLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IntervalSelector extends StatelessWidget {
  const _IntervalSelector({required this.provider});
  final WorkoutProvider provider;

  static const _options = [
    (seconds: 0,  label: '0'),
    (seconds: 2,  label: '2s'),
    (seconds: 5,  label: '5s'),
    (seconds: 15, label: '15s'),
    (seconds: 30, label: '30s'),
    (seconds: 60, label: '1 min'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: _options.asMap().entries.map((entry) {
          final idx = entry.key;
          final opt = entry.value;
          final selected = provider.announceIntervalSeconds == opt.seconds;
          return Expanded(
            child: Semantics(
              button: true,
              selected: selected,
              label: '${opt.seconds == 0 ? "continuous" : opt.label} announce interval${selected ? ", selected" : ""}',
              child: GestureDetector(
                onTap: () => provider.setAnnounceInterval(opt.seconds),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: selected ? kAccent : Colors.transparent,
                    borderRadius: BorderRadius.horizontal(
                      left: idx == 0 ? const Radius.circular(12) : Radius.zero,
                      right: idx == _options.length - 1 ? const Radius.circular(12) : Radius.zero,
                    ),
                  ),
                  child: ExcludeSemantics(
                    child: Text(
                      opt.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: selected ? Colors.white : kTextLabel,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        fontSize: 14,
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

class _DeltaSection extends StatelessWidget {
  const _DeltaSection({required this.provider});
  final WorkoutProvider provider;

  static const _thresholds = [
    (bpm: 3, label: '±3'),
    (bpm: 5, label: '±5'),
    (bpm: 8, label: '±8'),
    (bpm: 10, label: '±10'),
  ];

  @override
  Widget build(BuildContext context) {
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
                const Text(
                  'Announce on change',
                  style: TextStyle(color: kTextBright, fontSize: kFontLG),
                ),
                CupertinoSwitch(
                  value: provider.deltaAnnounceEnabled,
                  activeTrackColor: kAccent,
                  onChanged: provider.setDeltaAnnounceEnabled,
                ),
              ],
            ),
          ),
          if (provider.deltaAnnounceEnabled) ...[
            const Divider(color: kStopButton, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Threshold',
                    style: TextStyle(color: kTextLabel, fontSize: kFontBase, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: kSurfaceDark,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: _thresholds.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final opt = entry.value;
                        final selected = provider.deltaThreshold == opt.bpm;
                        return Expanded(
                          child: Semantics(
                            button: true,
                            selected: selected,
                            label: '${opt.label} BPM change threshold${selected ? ", selected" : ""}',
                            child: GestureDetector(
                              onTap: () => provider.setDeltaThreshold(opt.bpm),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: selected ? kAccent : Colors.transparent,
                                  borderRadius: BorderRadius.horizontal(
                                    left: idx == 0 ? const Radius.circular(8) : Radius.zero,
                                    right: idx == _thresholds.length - 1 ? const Radius.circular(8) : Radius.zero,
                                  ),
                                ),
                                child: ExcludeSemantics(
                                  child: Text(
                                    opt.label,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: selected ? Colors.white : kTextLabel,
                                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
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

class _HealthAuthSection extends StatelessWidget {
  const _HealthAuthSection({required this.provider});
  final WorkoutProvider provider;

  @override
  Widget build(BuildContext context) {
    final error = provider.healthFetchError;
    // HealthKit is already the active source for age — show the button as
    // disabled with an "Authorized" label so the user can see that HK is in
    // use without an action to take.
    final authorized = provider.healthAge != null && provider.manualAge == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kErrorBorder),
            ),
            child: Text(
              error,
              style: const TextStyle(color: kAccent, fontSize: kFontBase, height: 1.4),
            ),
          ),
          const SizedBox(height: 10),
        ],
        SizedBox(
          height: 44,
          child: provider.healthFetchPending
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  ),
                )
              : FilledButton(
                  onPressed: authorized ? null : () => provider.requestHealthZones(),
                  style: FilledButton.styleFrom(
                    backgroundColor: kSurface,
                    foregroundColor: kAccent,
                    side: BorderSide(color: authorized ? kTextDim : kAccent),
                    disabledBackgroundColor: kSurface,
                    disabledForegroundColor: kTextDim,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(
                    authorized
                        ? 'Health Access Authorized'
                        : (error != null ? 'Try Again' : 'Authorize Health Access'),
                  ),
                ),
        ),
      ],
    );
  }
}
