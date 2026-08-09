import Flutter
import StoreKit

/// StoreKit 2 wrapper for the two in-app purchases. Free-core by design: the
/// entitlement boolean and the tip jar both belong to the core — `isPlusUnlocked`
/// is the one choke point and it lives core-side. The Plus *features* stay in
/// lib/plus/; this only owns
/// "does the user own the unlock," surfaced to Flutter as a plain bool.
///
/// - Product IDs must match `iap_service.dart` and App Store Connect exactly.
/// - Entitlement is the source of truth: `Transaction.currentEntitlements`,
///   re-checked on launch, after any purchase/restore, and on every
///   `Transaction.updates` (Ask-to-Buy approvals, other-device purchases,
///   revocations). The latest value is pushed to Flutter on the
///   `steadyheartbeat/entitlements` EventChannel as `{"plus": Bool}`.
///
/// Concurrency: `plusEntitled` and `entitlementSink` are only ever touched on
/// the main thread (the Flutter channel + stream handlers run there, and every
/// write goes through the @MainActor `setPlusEntitled`).
final class StoreManager {
    static let shared = StoreManager()

    static let plusProductID = "com.halfmarble.steady_heart_beat.plus"
    static let tipProductID  = "com.halfmarble.steady_heart_beat.tip199"
    private static let productIDs = [plusProductID, tipProductID]

    private var cachedProducts: [Product] = []
    private var updatesTask: Task<Void, Never>?

    /// Pushed the entitlement payload on every change. Main-thread only.
    var entitlementSink: FlutterEventSink?
    /// Whether the Plus non-consumable is currently owned. Main-thread only.
    private(set) var plusEntitled = false

    private init() {}

    /// Begin watching transactions and resolve the launch entitlement. Safe to
    /// call once at app launch.
    func start() {
        updatesTask?.cancel()
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }
        Task { await refreshEntitlements() }
    }

    // MARK: - Products

    /// Localized product metadata for the paywall / tip UI. Empty if StoreKit is
    /// unreachable or the products aren't configured yet (pre-ASC) — the UI then
    /// shows its "not available yet" fallback rather than a broken buy button.
    func loadProducts() async -> [[String: Any]] {
        do {
            let products = try await Product.products(for: Self.productIDs)
            cachedProducts = products
            return products.map { p in
                [
                    "id": p.id,
                    "title": p.displayName,
                    "description": p.description,
                    "price": p.displayPrice, // already localized, e.g. "$4.99"
                ]
            }
        } catch {
            return []
        }
    }

    // MARK: - Purchase

    /// Buy a product by ID. Returns `{status: purchased|cancelled|pending|
    /// unavailable|failed|unknown, message?}`. On a verified purchase the
    /// entitlement is refreshed (which pushes the new value to Flutter).
    func purchase(_ productID: String) async -> [String: Any] {
        var product = cachedProducts.first(where: { $0.id == productID })
        if product == nil {
            // Not loaded yet (paywall opened before loadProducts finished).
            product = (try? await Product.products(for: [productID]))?.first
        }
        guard let product else { return ["status": "unavailable"] }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    // The user HAS been charged — StoreKit took the payment and
                    // handed back a transaction whose signature/date check did
                    // not pass. Reporting this as a plain failure tells a paying
                    // customer the purchase did not happen. It is its own state,
                    // with actionable advice (a wrong device clock is the usual
                    // cause), and the transaction is deliberately NOT finished so
                    // StoreKit redelivers it once verification succeeds.
                    return ["status": "unverified",
                            "message": "Your purchase went through, but this "
                                + "device could not verify it yet. Check that "
                                + "Date & Time is set automatically, then reopen "
                                + "the app — it will finish on its own."]
                }
                await transaction.finish()
                await refreshEntitlements()
                return ["status": "purchased"]
            case .userCancelled:
                return ["status": "cancelled"]
            case .pending:
                return ["status": "pending"]
            @unknown default:
                return ["status": "unknown"]
            }
        } catch {
            return ["status": "failed", "message": error.localizedDescription]
        }
    }

    // MARK: - Restore

    /// Mandatory for the non-consumable (App Review). Pulls down the user's
    /// transactions and re-resolves the entitlement; the result lands on the
    /// entitlement stream.
    ///
    /// THREE-STATE, not a Bool. "the sync failed" and "you own nothing" are
    /// opposite messages: collapsing them into one `ok` meant a paying customer
    /// with no network — or an Apple ID needing re-auth — was told there was no
    /// purchase to restore. `restored` / `nothingToRestore` / `failed` are
    /// distinguished here so the UI can say the right thing.
    func restore() async -> [String: Any] {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            // refreshEntitlements has already pushed the truth to Flutter; read
            // it back on the main actor for the synchronous answer.
            let owned = await MainActor.run { plusEntitled }
            return ["status": owned ? "restored" : "nothingToRestore"]
        } catch {
            return ["status": "failed", "message": error.localizedDescription]
        }
    }

    // MARK: - Entitlements

    func refreshEntitlements() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.plusProductID,
               transaction.revocationDate == nil {
                entitled = true
            }
        }
        await setPlusEntitled(entitled)
    }

    @MainActor
    private func setPlusEntitled(_ value: Bool) {
        guard value != plusEntitled else { return }
        plusEntitled = value
        entitlementSink?(["plus": value])
    }
}
