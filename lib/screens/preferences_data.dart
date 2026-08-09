part of 'preferences_screen.dart';

/// Preferences — the data-rights and notification sections.
///
/// `part` of preferences_screen.dart (see preferences_sections.dart for why).
/// This is the export / erase / donate surface: the one place the app
/// deliberately moves data out of its protected storage, and only on an
/// explicit tap. See DATA_PORTABILITY.md and DATA_PRIVACY.md before changing
/// anything here.

/// Lets the owner exercise their data rights: export a complete, plaintext copy
/// off-device via the system share sheet, or erase everything stored on the
/// device. The export is the one place the app deliberately moves data out of
/// its protected storage, and only on an explicit tap — see DATA_PORTABILITY.md.
class _YourDataSection extends StatefulWidget {
  const _YourDataSection({required this.provider});
  final WorkoutProvider provider;

  @override
  State<_YourDataSection> createState() => _YourDataSectionState();
}

class _YourDataSectionState extends State<_YourDataSection> {
  bool _exporting = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    // Refresh on open so the Export / Delete-All buttons reflect sessions added
    // or removed elsewhere (e.g. the Sessions screen) since launch.
    widget.provider.refreshSessionCount();
  }

  Future<void> _export() async {
    // Let the owner choose a plaintext copy (usable anywhere) or an anonymized
    // research donation. See DATA_PORTABILITY.md.
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Export My Data'),
        message: const Text(
            'A copy of your sessions and health profile, readable anywhere. Or '
            'contribute an anonymized copy to research.'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'plain'),
            child: const Text('Export a Copy'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'donate'),
            child: const Text('Anonymize for Research…'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final origin = _shareOrigin();

    if (choice == 'donate') {
      await _donate(origin);
      return;
    }

    setState(() => _exporting = true);
    final err = await ExportService.exportToShareSheet(origin: origin);
    if (!mounted) return;
    setState(() => _exporting = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not prepare your data for export. Please try again.'),
      ));
    }
  }

  /// A non-zero share-sheet anchor rect for this section. share_plus/iOS reject a
  /// zero-size sharePositionOrigin even on iPhone, so anchor to the real on-screen
  /// rect (fallback: a 1×1 rect at screen centre).
  Rect _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.of(context).size;
    return Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2), width: 1, height: 1);
  }

  /// Builds and shares an anonymized, OpenBioenergyGauge-shaped research donation
  /// after an explicit consent step. Nothing is uploaded — the user chooses where
  /// the file goes. See [DonationService].
  Future<void> _donate(Rect origin) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Contribute anonymized data'),
        content: const Text(
          '\nThis creates a file with your workout heart-rate timelines only — no '
          'name, age, sex, or conditions. Each session gets a random ID and its '
          'clock is shifted by a random amount (±7 days), so it can\'t be traced '
          'to you or to a daily schedule. Nothing is uploaded; you choose where to '
          'send the file.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create File'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _exporting = true);
    final err = await DonationService.shareDonation(origin: origin);
    if (!mounted) return;
    setState(() => _exporting = false);
    if (err == 'empty') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No finished workouts to contribute yet.'),
      ));
    } else if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not prepare the anonymized file. Please try again.'),
      ));
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('Delete all data?'),
        content: const Text(
          'This permanently removes your workout history and health profile '
          '(age, sex, conditions, and metrics) from this device. Your app '
          'settings are kept. This cannot be undone.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _deleting = true);
    final removed = await widget.provider.clearAllData();
    if (!mounted) return;
    setState(() => _deleting = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(removed == 1
          ? 'Deleted 1 session and your health profile.'
          : 'Deleted $removed sessions and your health profile.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final busy = _exporting || _deleting;
    final hasSessions = widget.provider.sessionCount > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Your data is yours. Export a complete, readable copy to keep or '
          'share — it leaves the app\'s protected storage. Or erase everything '
          'stored on this device.',
          style: TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        if (!hasSessions) ...[
          const SizedBox(height: 8),
          const Text(
            'No workouts recorded yet — finish a session to enable export and delete.',
            style: TextStyle(color: kTextDim, fontSize: kFontCaption, height: 1.3),
          ),
        ],
        const SizedBox(height: 14),
        SizedBox(
          height: 44,
          child: FilledButton(
            onPressed: (busy || !hasSessions) ? null : _export,
            style: FilledButton.styleFrom(
              backgroundColor: kSurface,
              foregroundColor: kAccent,
              side: BorderSide(color: (busy || !hasSessions) ? kTextDim : kAccent),
              disabledBackgroundColor: kSurface,
              disabledForegroundColor: kTextDim,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  )
                : const Text('Export My Data'),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 44,
          child: FilledButton(
            onPressed: (busy || !hasSessions) ? null : _confirmDelete,
            style: FilledButton.styleFrom(
              backgroundColor: kSurface,
              foregroundColor: kAccent,
              side: BorderSide(color: (busy || !hasSessions) ? kTextDim : kAccent),
              disabledBackgroundColor: kSurface,
              disabledForegroundColor: kTextDim,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: _deleting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  )
                : const Text('Delete All Data'),
          ),
        ),
        const SizedBox(height: 10),
        // Deliberately NOT gated on hasSessions — recovering lost sessions
        // from Apple Health is most needed when the local list is empty.
        SizedBox(
          height: 44,
          child: FilledButton(
            onPressed: busy
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ImportHealthScreen()),
                    ).then((_) => widget.provider.refreshSessionCount()),
            style: FilledButton.styleFrom(
              backgroundColor: kSurface,
              foregroundColor: kAccent,
              side: BorderSide(color: busy ? kTextDim : kAccent),
              disabledBackgroundColor: kSurface,
              disabledForegroundColor: kTextDim,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Import from Apple Health'),
          ),
        ),
      ],
    );
  }
}

class _NotificationsSection extends StatefulWidget {
  const _NotificationsSection();

  @override
  State<_NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<_NotificationsSection> with WidgetsBindingObserver {
  String _status = 'unknown';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Refresh on resume — user may have toggled the permission in Settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = await WorkoutService().getNotificationStatus();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _request() async {
    setState(() => _busy = true);
    await WorkoutService().requestNotificationPermission();
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openSettings() async {
    await launchUrl(Uri.parse('app-settings:'));
  }

  @override
  Widget build(BuildContext context) {
    final explanation = switch (_status) {
      'authorized' || 'provisional' || 'ephemeral' =>
        'Enabled. If iOS kills monitoring while the app is in the background, you\'ll get a notification so you know to restart it.',
      'denied' =>
        'Notifications are denied. If iOS kills monitoring in the background you won\'t know, and you\'ll keep exercising thinking it\'s still tracking. Open Settings to re-enable.',
      _ =>
        'iOS may kill background apps to free memory. With this on, you\'ll get a notification if monitoring stops mid-workout so you can restart it instead of silently losing the rest of the session.',
    };

    Widget? action;
    if (_status == 'notDetermined' || _status == 'unknown') {
      action = FilledButton(
        onPressed: _busy ? null : _request,
        style: FilledButton.styleFrom(
          backgroundColor: kSurface,
          foregroundColor: kAccent,
          side: const BorderSide(color: kAccent),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: _busy
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
              )
            : const Text('Enable Notifications'),
      );
    } else if (_status == 'denied') {
      action = FilledButton(
        onPressed: _openSettings,
        style: FilledButton.styleFrom(
          backgroundColor: kSurface,
          foregroundColor: kAccent,
          side: const BorderSide(color: kAccent),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: const Text('Open Settings'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          explanation,
          style: const TextStyle(color: kTextSubtle, fontSize: kFontBase, height: 1.4),
        ),
        if (action != null) ...[
          const SizedBox(height: 10),
          SizedBox(height: 44, child: action),
        ],
      ],
    );
  }
}
