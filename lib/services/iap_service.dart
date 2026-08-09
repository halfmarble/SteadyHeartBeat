import 'package:flutter/services.dart';

/// Core-side wrapper over the native StoreKit 2 layer (`StoreManager.swift`),
/// reached through the `steadyheartbeat/store` MethodChannel and the
/// `steadyheartbeat/entitlements` EventChannel.
///
/// Free-core on purpose: the Plus entitlement bool and the tip jar are both
/// core concerns — only the paid *features* live in `lib/plus/`. The provider
/// pushes the entitlement into the module via `PlusFeatures.setUnlocked`; this
/// service never imports `lib/plus/`.
class IapService {
  static const _method = MethodChannel('steadyheartbeat/store');
  static const _entitlements = EventChannel('steadyheartbeat/entitlements');

  /// Product IDs — must match `StoreManager.swift` and the App Store Connect
  /// listing exactly. Changing one without the others silently breaks purchase.
  static const plusProductId = 'com.halfmarble.steady_heart_beat.plus';
  static const tipProductId = 'com.halfmarble.steady_heart_beat.tip199';

  /// Localized products for sale, each `{id, title, description, price}`.
  /// Empty when StoreKit is unreachable or the products aren't configured yet
  /// (pre-ASC) — callers fall back to "not available yet" copy.
  Future<List<Map<String, dynamic>>> products() async {
    final result = await _method.invokeMethod<List<dynamic>>('products');
    return (result ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Starts a purchase. Returns the native status map: `{status:
  /// purchased|cancelled|pending|unavailable|failed|unknown, message?}`. A
  /// verified purchase updates the entitlement, which arrives on [plusEntitled].
  Future<Map<String, dynamic>> buy(String productId) async {
    final result = await _method
        .invokeMapMethod<String, dynamic>('buy', {'productId': productId});
    return result ?? const {'status': 'unknown'};
  }

  /// Restores prior purchases — mandatory for the non-consumable (App Review).
  /// The resulting entitlement lands on [plusEntitled].
  Future<Map<String, dynamic>> restore() async {
    final result = await _method.invokeMapMethod<String, dynamic>('restore');
    return result ?? const {'status': 'unknown'};
  }

  /// One-shot entitlement read. The stream is the live source of truth; this is
  /// for a synchronous startup check if ever needed.
  Future<bool> isPlusEntitled() async {
    final result = await _method.invokeMethod<bool>('isPlusEntitled');
    return result ?? false;
  }

  /// Live entitlement: true when the Plus unlock is owned. Fires once on listen
  /// with the current value, then on every change (purchase, restore,
  /// other-device sync, revocation).
  Stream<bool> get plusEntitled =>
      _entitlements.receiveBroadcastStream().map((e) =>
          (Map<String, dynamic>.from(e as Map)['plus'] as bool?) ?? false);
}
