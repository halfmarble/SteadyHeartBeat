part of 'home_screen.dart';

/// Home — the control bar and its animated affordances: the BPM-beating
/// workout icon, the sensor-search indicator and its painter, the loading
/// button.
///
/// `part` of home_screen.dart (see home_live_view.dart for why).

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
      if (bytes == null) {
        // Transient failure (e.g. a race right at startup): un-latch so a
        // later instance retries — latching here used to leave the AirPods
        // artwork missing for the rest of the app session.
        _fetchAttempted = false;
        return;
      }
      _cachedBytes = bytes;
      if (mounted) {
        setState(() => _iconBytes = bytes);
        await _decodeUiImage(bytes);
      }
    } catch (_) {
      _fetchAttempted = false;
    }
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
      // TickerMode is off while another route fully covers this screen —
      // skip the repaint there so the idle shimmer doesn't keep burning
      // CPU/battery at 12.5 fps underneath Preferences or a session detail.
      if (mounted && TickerMode.getValuesNotifier(context).value.enabled) {
        setState(() => _noiseSeed++);
      }
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
