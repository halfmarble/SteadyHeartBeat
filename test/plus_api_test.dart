import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_heart_beat/plus_api.dart';

// Pins the inertness of NoPlusFeatures — the binding the PUBLIC build actually
// ships. Every member must stay a no-op: the free core's behavior (and the
// open-core promise that nothing paid is reachable) rests on it. This is a
// core test, so the exported public repo runs it too.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NoPlusFeatures (the free-core binding)', () {
    test('reports absent and locked, and stays locked', () async {
      final plus = NoPlusFeatures();
      expect(plus.available, isFalse);
      expect(plus.unlocked, isFalse);
      expect(plus.gateActive, isFalse);

      // The entitlement push must not be able to unlock anything.
      plus.setUnlocked(true);
      expect(plus.unlocked, isFalse);
      expect(plus.available, isFalse);
    });

    test('event and prefs hooks are inert', () async {
      final plus = NoPlusFeatures();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      plus.loadPrefs(prefs);
      await plus.savePrefs(prefs);
      expect(prefs.getKeys(), isEmpty,
          reason: 'the inert binding must not write any preference');

      plus.onWorkoutStart();
      plus.onRoundEvent(const {
        'gated': true,
        'targetBpm': 110,
        'currentBpm': 124,
        'elapsed': 30,
      });
      expect(plus.gateActive, isFalse,
          reason: 'a gated round event must not surface paid gate state');
    });

    testWidgets('builds no paid UI and opens no routes', (tester) async {
      final plus = NoPlusFeatures();
      final observer = _CountingNavigatorObserver();
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [observer],
        home: Builder(builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        }),
      ));

      expect(plus.preferencesSection(ctx), isNull);
      expect(plus.roundBanner(ctx, 'rest'), isNull);

      final pushesBefore = observer.pushes;
      plus.openTrends(ctx, 'hrv');
      await tester.pumpAndSettle();
      expect(observer.pushes, pushesBefore,
          reason: 'openTrends must not navigate anywhere in the free core');
    });
  });
}

class _CountingNavigatorObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}
