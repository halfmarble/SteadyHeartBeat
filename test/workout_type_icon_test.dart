import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_heart_beat/widgets/workout_type_icon.dart';
import 'package:steady_heart_beat/providers/workout_provider.dart';

// Guards BUGS.md #2: boxing must ALWAYS render as a mirrored pair of gloves, and
// every other type as exactly one icon. Routing every surface through
// WorkoutTypeIcon is what keeps this from drifting per-screen.

Finder _gloves() => find.byWidgetPredicate(
    (w) => w is Icon && w.icon == Icons.sports_mma);

Future<void> _pump(WidgetTester t, WorkoutType type) => t.pumpWidget(
      MaterialApp(
        home: WorkoutTypeIcon(type: type, size: 22, color: const Color(0xFFFFFFFF)),
      ),
    );

void main() {
  testWidgets('boxing renders a mirrored pair — two gloves', (t) async {
    await _pump(t, WorkoutType.boxing);
    expect(_gloves(), findsNWidgets(2));
  });

  testWidgets('every non-boxing type renders exactly one icon, no glove', (t) async {
    for (final type in WorkoutType.values) {
      if (type == WorkoutType.boxing) continue;
      await _pump(t, type);
      expect(find.byType(Icon), findsOneWidget,
          reason: '$type should be a single icon');
      expect(_gloves(), findsNothing, reason: '$type must not show a boxing glove');
    }
  });
}
