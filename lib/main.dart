import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/workout_provider.dart';
import 'app.dart';

void main() {
  // Backstop for anything an individual call site doesn't catch — e.g. a
  // platform-channel call that throws (PlatformException / MissingPluginException)
  // instead of returning a failure value. In release these would otherwise be
  // swallowed silently; here we at least log them. Per-feature error UI still
  // lives at the call sites (see WorkoutProvider.start).
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();

    // Framework (build/layout/paint) errors → console + zone handler.
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      Zone.current.handleUncaughtError(details.exception, details.stack ?? StackTrace.empty);
    };

    // Uncaught async errors from the engine/platform side.
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught platform error: $error\n$stack');
      return true; // handled — don't crash the app
    };

    runApp(
      ChangeNotifierProvider(
        create: (_) => WorkoutProvider(),
        child: const SteadyHeartBeatApp(),
      ),
    );
  }, (error, stack) {
    debugPrint('Uncaught zone error: $error\n$stack');
  });
}
