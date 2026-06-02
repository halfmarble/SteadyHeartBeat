import 'package:flutter/services.dart';

/// Voice announcements via native AVSpeechSynthesizer (iOS).
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

  Future<void> speak(String text) async {
    await _channel.invokeMethod('speak', {'text': text});
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stopSpeaking');
  }

  Future<void> dispose() async {
    await _channel.invokeMethod('stopSpeaking');
  }
}
