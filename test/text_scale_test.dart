import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:steady_heart_beat/app.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';
import 'helpers/fakes.dart';

// Dynamic Type policy: text follows the system scale, clamped to [1.0, 1.4] —
// large accessibility sizes scale the UI without clipping the fixed-height
// chrome, and "smaller text" settings never shrink workout-critical numbers.
// Exercises the real SteadyHeartBeatApp builder with the home screen mounted.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = FakeWakelock();

  Future<TextScaler> scalerUnder(WidgetTester tester, double system) async {
    SharedPreferences.setMockInitialValues({});
    final provider =
        WorkoutProvider(workout: FakeWorkoutService(), tts: FakeTtsService());
    await tester.pumpWidget(
      ChangeNotifierProvider<WorkoutProvider>.value(
        value: provider,
        child: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(system)),
          child: const SteadyHeartBeatApp(),
        ),
      ),
    );
    // Any context below the app's builder sees the clamped scaler.
    final ctx = tester.element(find.byType(Scaffold).first);
    final scaler = MediaQuery.textScalerOf(ctx);
    // Let the idle screen's delayed AirPods-icon fetch fire (800 ms one-shot),
    // then unmount and dispose so no timer trips the pending-timers invariant.
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
    return scaler;
  }

  testWidgets('system scale 3.0 is clamped to 1.4', (tester) async {
    final scaler = await scalerUnder(tester, 3.0);
    expect(scaler.scale(10), closeTo(14, 0.01));
  });

  testWidgets('system scale 0.8 is floored to 1.0', (tester) async {
    final scaler = await scalerUnder(tester, 0.8);
    expect(scaler.scale(10), closeTo(10, 0.01));
  });

  testWidgets('an in-range scale passes through', (tester) async {
    final scaler = await scalerUnder(tester, 1.2);
    expect(scaler.scale(10), closeTo(12, 0.01));
  });
}
