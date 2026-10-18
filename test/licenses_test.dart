// The open-source notices: the two that Flutter cannot collect are registered
// once, main() registers them, and the About section's link opens Flutter's
// license page.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';
import 'package:steady_heart_beat/licenses.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';
import 'package:steady_heart_beat/screens/preferences_screen.dart';
import 'helpers/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = FakeWakelock();

  Future<String> noticeFor(String package) async {
    final entries = await LicenseRegistry.licenses
        .where((e) => e.packages.contains(package))
        .toList();
    expect(entries, hasLength(1), reason: '$package registered once');
    return entries.single.paragraphs.map((p) => p.text).join('\n');
  }

  test('the voice and icon-font notices are registered once each', () async {
    registerAppLicenses();
    registerAppLicenses();
    final kokoro = await noticeFor('Kokoro-82M');
    expect(kokoro, contains('Apache License 2.0'));
    expect(kokoro, contains('hexgrad'));
    expect(kokoro, contains('StyleTTS 2'));
    final icons = await noticeFor('Material Icons');
    expect(icons, contains('creativecommons.org/licenses/by/4.0'));
  });

  // The test above calls registerAppLicenses() itself, so only a source scan
  // notices if main() stops calling it and the notices drop out of the app.
  test('main() registers the app licenses before runApp', () {
    final src = File('lib/main.dart').readAsStringSync();
    final register = src.indexOf('registerAppLicenses();');
    expect(register, greaterThan(-1));
    expect(register, lessThan(src.indexOf('runApp(')));
  });

  testWidgets('the About link opens the license page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider =
        WorkoutProvider(workout: FakeWorkoutService(), tts: FakeTtsService());
    await tester.pumpWidget(
      ChangeNotifierProvider<WorkoutProvider>.value(
        value: provider,
        child: const MaterialApp(home: PreferencesScreen()),
      ),
    );
    final link = find.text('Open-source licenses');
    await tester.scrollUntilVisible(link, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });
}
