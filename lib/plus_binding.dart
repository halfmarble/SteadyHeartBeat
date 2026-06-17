import 'plus_api.dart';
import 'providers/workout_provider.dart';

/// PUBLIC-EXPORT BINDING — the free core has no paid module compiled in, so
/// every PlusFeatures member is inert. In the private repo this file binds the
/// real Plus implementation instead. The two versions must keep an identical
/// signature.
PlusFeatures createPlusFeatures(WorkoutProvider provider) => NoPlusFeatures();
