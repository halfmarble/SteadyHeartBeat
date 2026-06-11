import 'package:flutter/material.dart';
import '../providers/workout_provider.dart' show WorkoutType;

/// The single source of truth for a workout-type icon.
///
/// Boxing always renders as a mirrored **pair** of gloves (left + a horizontally
/// flipped right); every other type is its single Material icon. Route every
/// workout-type icon through this widget so boxing can't drift back to a lone
/// glove on some surfaces (see BUGS.md #2 — this consolidates three inline pair
/// implementations and the bare-`sports_mma` fallbacks).
class WorkoutTypeIcon extends StatelessWidget {
  const WorkoutTypeIcon({
    super.key,
    required this.type,
    required this.size,
    required this.color,
  });

  final WorkoutType type;
  final double size;
  final Color color;

  /// The single Material glyph for a type. Boxing maps to one glove here; the
  /// widget itself decides to draw the *pair*, so callers never use this for
  /// boxing directly.
  static IconData iconData(WorkoutType type) => switch (type) {
        WorkoutType.boxing => Icons.sports_mma,
        WorkoutType.cycling => Icons.directions_bike,
        WorkoutType.running => Icons.directions_run,
        WorkoutType.walking => Icons.directions_walk,
        WorkoutType.hiking => Icons.hiking,
        WorkoutType.other => Icons.fitness_center,
      };

  @override
  Widget build(BuildContext context) {
    if (type != WorkoutType.boxing) {
      return Icon(iconData(type), size: size, color: color);
    }
    // Mirrored pair: width ~1.7× the glyph so the two gloves sit side by side
    // with a slight overlap (matches the long-standing inline versions).
    return SizedBox(
      width: size * 1.7,
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Icon(Icons.sports_mma, size: size, color: color),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(-1, 1, 1),
              child: Icon(Icons.sports_mma, size: size, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
