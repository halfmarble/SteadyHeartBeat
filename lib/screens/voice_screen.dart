import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../providers/workout_provider.dart';
import '../constants.dart';
import '../widgets/app_chrome.dart';

/// Dedicated voice picker. Lists every English voice installed on the iPhone
/// (best quality first), lets the user sample each, and pick one — or leave it
/// on "Automatic", which uses the highest-quality installed voice (Option A).
///
/// Higher-quality (Premium / Enhanced) voices are on-device downloads the user
/// installs through iOS Settings — the instructions card explains how, since
/// Apple's voices can't be bundled into a third-party app.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> with WidgetsBindingObserver {
  // Representative of a real announcement so the sample shows how numbers sound.
  static const _sampleText = 'Heart rate 142.';

  List<Map<String, dynamic>> _voices = [];
  String _resolved = '';     // identifier the announce path currently resolves to
  bool _loading = true;
  String? _previewing;       // identifier whose sample is currently playing

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Silently re-query installed voices when the app returns to the foreground —
  // catches voices the user just downloaded in Settings without making them
  // restart the app or even leave this page (_load doesn't flip _loading, so the
  // list updates in place with no spinner flash).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final provider = context.read<WorkoutProvider>();
    final all = await provider.availableVoices();
    final resolved = await provider.resolvedVoiceIdentifier();
    if (!mounted) return;
    // Only surface the good voices (Premium / Enhanced). If the user hasn't
    // downloaded any yet, fall back to the first 5 of the built-in defaults so
    // the page isn't empty (the native list is already sorted best-first).
    final better = all.where((v) {
      final q = v['quality'] as String?;
      return q == 'premium' || q == 'enhanced';
    }).toList();
    setState(() {
      _voices = better.isNotEmpty ? better : all.take(5).toList();
      _resolved = resolved;
      _loading = false;
    });
  }

  void _select(String? identifier, String? name) {
    context.read<WorkoutProvider>().setVoice(identifier, name: name);
    setState(() {}); // reflect the new selection immediately
  }

  Future<void> _preview(String identifier) async {
    setState(() => _previewing = identifier);
    await context.read<WorkoutProvider>().previewVoice(identifier, text: _sampleText);
    // The native sample fires-and-forgets; clear the spinner after a short beat.
    await Future.delayed(const Duration(milliseconds: 1600));
    if (mounted) setState(() => _previewing = null);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WorkoutProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice'),
        leading: backButton(context),
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              children: [
                const _DownloadInstructions(),
                const SizedBox(height: 24),
                _AutoRow(
                  selected: provider.voiceIdentifier == null,
                  resolvedName: _resolvedName(),
                  onTap: () => _select(null, null),
                ),
                const SizedBox(height: 24),
                ..._buildVoiceList(provider.voiceIdentifier),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  String _resolvedName() {
    final match = _voices.firstWhere(
      (v) => v['identifier'] == _resolved,
      orElse: () => const {},
    );
    return (match['name'] as String?) ?? '';
  }

  // Flat list in the native order (current locale first, then quality/size,
  // then name). Quality is shown as a per-row badge rather than section headers,
  // so locale-matching voices can lead regardless of tier.
  List<Widget> _buildVoiceList(String? selectedId) {
    return _voices.map((v) {
      final id = v['identifier'] as String;
      return _VoiceRow(
        name: v['name'] as String? ?? 'Voice',
        quality: v['quality'] as String? ?? 'default',
        gender: v['gender'] as String? ?? '',
        language: v['language'] as String? ?? '',
        selected: selectedId == id,
        previewing: _previewing == id,
        onTap: () => _select(id, v['name'] as String?),
        onPreview: () => _preview(id),
      );
    }).toList();
  }
}

// ── Download instructions (the user can only get Premium voices via iOS) ───────

class _DownloadInstructions extends StatelessWidget {
  const _DownloadInstructions();

  @override
  Widget build(BuildContext context) {
    const steps = [
      'Open the iPhone Settings app.',
      'Go to Accessibility → Read & Speak → Voices → English. '
          '(On iOS 18 and earlier, Read & Speak is called Spoken Content.)',
      'Tap the Voice row, then choose a named voice — Ava, Zoe, Evan or Nathan — '
          'and download its Premium or Enhanced version.',
      'Come back here — the named voice appears in the list below.',
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kAccent.withAlpha(kAlphaMid)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(CupertinoIcons.info_circle, size: kIconXS, color: kAccent),
              const SizedBox(width: 8),
              Text(
                'Want a higher-quality voice?',
                style: const TextStyle(
                  color: kTextBright,
                  fontSize: kFontLG,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Apple’s best voices are free downloads on your iPhone — they can’t be '
            'built into the app. Once downloaded, pick one below.',
            style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
          ),
          const SizedBox(height: 12),
          for (int i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i + 1}.',
                    style: const TextStyle(
                      color: kAccent,
                      fontSize: kFontBase,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      steps[i],
                      style: const TextStyle(
                        color: kTextMuted,
                        fontSize: kFontBase,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: kSurfaceDark,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'The “Voice 1–5” options in Settings are Siri’s voices. They sound '
              'great, but Apple keeps them system-only — apps can’t use or list '
              'them. Pick a named voice instead.',
              style: TextStyle(color: kTextSubtle, fontSize: kFontCaption, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Rows ───────────────────────────────────────────────────────────────────────

class _AutoRow extends StatelessWidget {
  const _AutoRow({
    required this.selected,
    required this.resolvedName,
    required this.onTap,
  });

  final bool selected;
  final String resolvedName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = resolvedName.isEmpty ? 'Best available' : 'Using $resolvedName';
    return Semantics(
      button: true,
      selected: selected,
      label: 'Automatic voice, $sub${selected ? ", selected" : ""}',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? kAccent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: ExcludeSemantics(
            child: Row(
              children: [
                Icon(CupertinoIcons.sparkles,
                    size: kIconSM, color: selected ? kAccent : kTextLabel),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Automatic',
                          style: TextStyle(color: kTextBright, fontSize: kFontLG)),
                      const SizedBox(height: 2),
                      Text(sub,
                          style: const TextStyle(color: kTextSubtle, fontSize: kFontCaption)),
                    ],
                  ),
                ),
                if (selected)
                  const Icon(CupertinoIcons.check_mark_circled_solid,
                      size: kIconSM, color: kAccent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.quality});
  final String quality;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (quality) {
      'premium'  => ('PREMIUM', kZone3),   // gold — the large neural voices
      'enhanced' => ('ENHANCED', kCyan),
      _          => ('STANDARD', kTextLabel),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(kAlphaLow),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(kAlphaMid)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: kFontXS,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _VoiceRow extends StatelessWidget {
  const _VoiceRow({
    required this.name,
    required this.quality,
    required this.gender,
    required this.language,
    required this.selected,
    required this.previewing,
    required this.onTap,
    required this.onPreview,
  });

  final String name;
  final String quality;
  final String gender;
  final String language;
  final bool selected;
  final bool previewing;
  final VoidCallback onTap;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (gender.isNotEmpty && gender != 'unspecified') _cap(gender),
      if (language.isNotEmpty) language,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: selected,
        label: '$name voice${meta.isNotEmpty ? ", $meta" : ""}${selected ? ", selected" : ""}',
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? kAccent : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Quality badge sits above the voice name.
                        _QualityBadge(quality: quality),
                        const SizedBox(height: 4),
                        Text(name,
                            style: const TextStyle(
                                color: kTextBright, fontSize: kFontLG)),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(meta,
                              style: const TextStyle(
                                  color: kTextSubtle, fontSize: kFontCaption)),
                        ],
                      ],
                    ),
                  ),
                  // Sample button — semantics kept (not excluded) so it's a
                  // distinct, labelled action for VoiceOver users.
                  Semantics(
                    button: true,
                    label: 'Play sample of $name',
                    child: GestureDetector(
                      onTap: onPreview,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: previewing
                            ? const SizedBox(
                                width: kIconSM,
                                height: kIconSM,
                                child: CupertinoActivityIndicator(radius: 9))
                            : const Icon(CupertinoIcons.play_circle,
                                size: kIconSM, color: kAccent),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    selected
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.circle,
                    size: kIconSM,
                    color: selected ? kAccent : kTextGhost,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
