import 'package:flutter/material.dart';
import '../constants.dart';

/// Upgrade teaser shown when a paid surface (e.g. daily trends) is tapped
/// without the SHB+ unlock — both in the free core and in the paid build while
/// locked. Placeholder copy until the StoreKit paywall lands (no purchase flow
/// is wired yet); for now it explains what SHB+ adds.
Future<void> showPlusTeaser(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
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
              'SHB+ charts your bed HRV night to night so you can watch your own '
              'baseline trend over time, instead of just today’s reading.',
              style: TextStyle(
                  color: kTextSubtle, fontSize: kFontMD, height: 1.45),
            ),
            const SizedBox(height: 12),
            const Text(
              'The upgrade isn’t available to purchase yet — it’s coming in a '
              'future update.',
              style: TextStyle(
                  color: kTextDim, fontSize: kFontCaption, height: 1.4),
            ),
          ],
        ),
      ),
    ),
  );
}
