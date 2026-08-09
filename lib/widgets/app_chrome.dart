import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../constants.dart';

/// Shared app chrome — the two shapes that every pushed screen and every
/// bottom sheet in the app repeats verbatim.
///
/// Extracted because both had drifted into 8 (back button) and 6 (sheet)
/// byte-identical copies across the app. Keeping one copy means a
/// tap-target, Semantics or safe-area fix lands everywhere at once instead of
/// in whichever screen someone remembered.
///
/// This file is core: it must not reference any optional module, because every
/// build has to compile with this file and nothing else.

/// The standard back affordance for a pushed screen — `AppBar.leading`.
///
/// `CupertinoButton` rather than the Material default so the hit area and the
/// press animation match the rest of the iOS-styled UI; the [Semantics] label
/// is what VoiceOver reads, since a bare chevron has no accessible name.
Widget backButton(BuildContext context) => CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: () => Navigator.pop(context),
      child: Semantics(
        button: true,
        label: 'Back',
        child: const Icon(CupertinoIcons.back, color: kAccent),
      ),
    );

/// The compact, letter-spaced AppBar title used by the pushed data screens
/// (Sessions, Import, Trends). The Preferences stack deliberately keeps the
/// default Material title style — passing a plain `Text` there is correct.
Widget appBarTitle(String text) => Text(text,
    style: const TextStyle(
        fontSize: kFontLG, fontWeight: FontWeight.w600, letterSpacing: 0.5));

/// The app's bottom sheet: dark surface, rounded top, grab handle, title, then
/// [children] in a scroll view.
///
/// Height is capped at 85% of the screen so the tap-to-dismiss scrim and the
/// grabber stay reachable on long content, and the body scrolls inside that
/// cap rather than overflowing — previously only the metric explainer did
/// this, so other explainer sheets could overflow on small devices with large
/// text. Applying it everywhere is the one intentional behavior change in this
/// extraction.
///
/// The cap is measured INSIDE the builder, via [MediaQuery.sizeOf] on the
/// sheet's own context, not from the caller's. Passing `constraints:` to
/// `showModalBottomSheet` freezes the value at the orientation the sheet was
/// opened in — the route stores it once — so a sheet opened in landscape stayed
/// a squat box after rotating to portrait. Trends is the one screen that
/// rotates, and its ten explainers all come through here. Reading it here also
/// keeps the *caller* (a chart card) from taking an inherited-widget dependency
/// on MediaQuery and rebuilding on every metrics change.
Future<void> showAppSheet({
  required BuildContext context,
  required String title,
  required List<Widget> children,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => sheetBody(ctx, title: title, children: children),
  );
}

/// The sheet's inner layout — capped, scrollable, grab handle and title.
///
/// Public so a sheet whose body must be STATEFUL — and therefore cannot pass a
/// fixed `children` list to [showAppSheet] — still gets the same cap and the
/// same scroll behavior instead of re-deriving them. A sheet that re-derived
/// them is exactly how one ended up able to clip its own primary action.
Widget sheetBody(
  BuildContext ctx, {
  required String title,
  required List<Widget> children,
}) {
  return ConstrainedBox(
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetGrabHandle(),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: kFontXL,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The drag indicator at the top of a sheet.
///
/// Public for [sheetBody] and for any sheet building its own stateful body.
/// NOT used by pre_workout_sheet.dart — both of its sheets take Material's
/// `showDragHandle: true` instead, so an accessibility change here (bigger drag
/// target, more contrast than [kTextDim]) does not reach them.
class SheetGrabHandle extends StatelessWidget {
  const SheetGrabHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.only(bottom: 18),
          decoration: BoxDecoration(
            color: kTextDim,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

/// A run of body paragraphs in the sheet's text style — the tail of every
/// explainer sheet.
List<Widget> sheetParagraphs(List<String> paragraphs) => [
      for (final p in paragraphs) ...[
        Text(p,
            style: const TextStyle(
                color: kTextSubtle, fontSize: kFontMD, height: 1.45)),
        const SizedBox(height: 12),
      ],
    ];
