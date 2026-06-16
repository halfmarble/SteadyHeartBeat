import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../providers/workout_provider.dart';
import '../services/iap_service.dart';

/// SHB+ paywall, shown when a paid surface (e.g. daily trends) is tapped without
/// the unlock — both in the free core (so free users see what the upgrade adds)
/// and in the paid build while locked.
///
/// One-time, non-consumable purchase (docs/SHB_PLUS_PRICING.md) with a mandatory
/// Restore Purchases action. Price is read live from StoreKit so it tracks the
/// App Store Connect price without a code change. If StoreKit has no product
/// yet (pre-ASC, offline), it falls back to a "not available to purchase yet"
/// state instead of a broken buy button.
Future<void> showPlusTeaser(BuildContext context) async {
  final provider = context.read<WorkoutProvider>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _PaywallSheet(provider: provider),
  );
}

class _PaywallSheet extends StatefulWidget {
  const _PaywallSheet({required this.provider});
  final WorkoutProvider provider;

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  Map<String, dynamic>? _plusProduct; // null until products load
  bool _loading = true;
  bool _busy = false; // a purchase / restore is in flight
  String? _message; // transient status line under the buttons

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    final products = await widget.provider.plusProducts();
    if (!mounted) return;
    setState(() {
      _plusProduct = products
          .cast<Map<String, dynamic>?>()
          .firstWhere((p) => p?['id'] == IapService.plusProductId,
              orElse: () => null);
      _loading = false;
    });
  }

  // If the entitlement flips to unlocked mid-sheet (purchase or restore landed),
  // close — the gated surface behind us re-renders unlocked.
  bool get _unlocked => widget.provider.plus.unlocked;

  Future<void> _buy() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await widget.provider.buyPlus();
    if (!mounted) return;
    final status = result['status'] as String?;
    if (status == 'purchased') {
      if (_unlocked && mounted) Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _message = switch (status) {
        'cancelled' => null, // user backed out — no scary message
        'pending' => 'Your purchase is pending approval.',
        'unavailable' => 'This purchase isn’t available right now.',
        _ => 'Purchase didn’t complete. Please try again.',
      };
    });
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    await widget.provider.restorePurchases();
    if (!mounted) return;
    if (_unlocked) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _message = 'No previous purchase found to restore.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final price = _plusProduct?['price'] as String?;
    final purchasable = _plusProduct != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: kTextDim,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Daily trends are part of SHB+',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: kFontXL,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            const Text(
              'SHB+ charts your bed HRV, bed HR, and VO₂ max night to night, so '
              'you can watch your own baseline trend over time instead of seeing '
              'only today’s reading.',
              style:
                  TextStyle(color: kTextSubtle, fontSize: kFontMD, height: 1.45),
            ),
            const SizedBox(height: 18),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: kAccent))),
              )
            else if (purchasable) ...[
              _BuyButton(
                label: price == null ? 'Unlock SHB+' : 'Unlock SHB+ · $price',
                busy: _busy,
                onPressed: _busy ? null : _buy,
              ),
              const SizedBox(height: 8),
              const Text(
                'A one-time purchase, not a subscription. Yours forever — future '
                'SHB+ features included.',
                style: TextStyle(
                    color: kTextDim, fontSize: kFontCaption, height: 1.4),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: _busy ? null : _restore,
                  child: const Text('Restore Purchases',
                      style: TextStyle(color: kAccent, fontSize: kFontMD)),
                ),
              ),
            ] else
              const Text(
                'The upgrade isn’t available to purchase yet — it’s coming in a '
                'future update.',
                style: TextStyle(
                    color: kTextDim, fontSize: kFontCaption, height: 1.4),
              ),
            if (_message != null) ...[
              const SizedBox(height: 6),
              Text(_message!,
                  style: const TextStyle(
                      color: kTextSubtle, fontSize: kFontCaption, height: 1.4)),
            ],
          ],
        ),
      ),
    );
  }
}

class _BuyButton extends StatelessWidget {
  const _BuyButton(
      {required this.label, required this.busy, required this.onPressed});
  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: kAccent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: kAccent,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : Text(label,
                style: const TextStyle(
                    fontSize: kFontMD, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
