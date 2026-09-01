import 'package:flutter/services.dart';

/// Voice announcements, rendered natively (iOS).
///
/// The voice is Kokoro-82M through Core ML — either a pre-rendered clip or a
/// live render — played through the app's own AVAudioEngine. AVSpeechSynthesizer
/// is the fallback tier only. See ios/Runner/AnnounceEngine.swift and
/// ios/Runner/Kokoro/. Nothing is synthesized on the Dart side; this class is a
/// MethodChannel shim.
///
/// The native side (WorkoutManager) owns the AVAudioSession that the workout
/// activates and holds active for the whole workout (no per-utterance
/// deactivation — AirPods Pro 3 won't let us reactivate from the background
/// after deactivating). It listens for interruption / route-change
/// notifications to reactivate after a call/Siri. This avoids the flutter_tts
/// plugin-boundary lifecycle bug that left background utterances silent after
/// the first one or two.
class TtsService {
  static const _channel = MethodChannel('steadyheartbeat/workout');

  Future<void> init() async {
    // Voice + audio session are configured natively when the workout starts;
    // nothing to do here. Kept as a hook for test fakes.
  }

  /// Selects the announce voice by its system identifier. An empty string means
  /// "automatic" — native falls back to the best available voice (Option A).
  Future<void> setVoice(String identifier) async {
    await _channel.invokeMethod('setVoice', {'identifier': identifier});
  }

  /// Speaks [text]. Announcements queue natively and are never interrupted —
  /// a cue requested while another is speaking plays right after it (a newer
  /// BPM replaces a BPM still waiting in the queue). [force] marks
  /// preference-change feedback: native skips the BPM cooldown so the cue is
  /// heard immediately even right after a regular announcement.
  Future<void> speak(String text, {bool force = false}) async {
    await _channel.invokeMethod('speak', {'text': text, 'force': force});
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stopSpeaking');
  }

  Future<void> dispose() async {
    await _channel.invokeMethod('stopSpeaking');
  }
}
