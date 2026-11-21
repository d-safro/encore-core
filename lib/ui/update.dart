import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/settings.dart';
import '../desktop/desktop.dart' show quitApp;
import '../data/updates.dart';
import 'actions.dart';

/// "Encore 1.7.0 is available": what's new, and Update / Later / Skip this version.
Future<void> showUpdateDialog(BuildContext context, UpdateInfo u, {bool fromCheck = false}) async {
  final mb = u.size > 0 ? ' · ${(u.size / 1048576).toStringAsFixed(0)} MB' : '';
  final go = await showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.system_update_rounded),
      title: Text('Encore ${u.version} is available'),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.45),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('You have $appVersion$mb', style: Theme.of(ctx).textTheme.bodySmall),
              if (u.notes.isNotEmpty) ...[const SizedBox(height: 12), Text(_plain(u.notes))],
            ],
          ),
        ),
      ),
      actions: [
        if (!fromCheck) TextButton(onPressed: () => Navigator.pop(ctx, 'skip'), child: const Text('Skip this version')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
        FilledButton(onPressed: () => Navigator.pop(ctx, 'update'), child: const Text('Update')),
      ],
    ),
  );
  if (go == 'skip') await prefs.setString('updateSkipped', u.version);
  if (go == 'update' && context.mounted) {
    await showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _UpdateSheet(u),
    );
  }
}

/// Release notes are Markdown; show them as plain text.
String _plain(String md) => md
    .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m[1]!)
    .replaceAll(RegExp(r'^- ', multiLine: true), '• ')
    .trim();

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet(this.u);
  final UpdateInfo u;
  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> with WidgetsBindingObserver {
  double _progress = 0;
  String _status = 'Downloading…';
  File? _file;
  bool _failed = false, _needsPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _download();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // back from Android's "Install unknown apps" page: carry on if it was allowed
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _needsPermission) _install();
  }

  Future<void> _download() async {
    setState(() {
      _failed = false;
      _status = 'Downloading…';
      _progress = 0;
    });
    try {
      final f = await downloadUpdate(widget.u, (p) {
        if (mounted) setState(() => _progress = p);
      });
      _file = f;
      await _install();
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = "Couldn't download the update: $e";
        });
      }
    }
  }

  Future<void> _install() async {
    final f = _file;
    if (f == null || !mounted) return;
    if (isDesktop) return _installDesktop(f);
    if (!await canInstallUpdates()) {
      setState(() {
        _needsPermission = true;
        _status = 'Android needs your OK to let Encore install its updates. Turn on "Allow from this source", then come back.';
      });
      return;
    }
    setState(() {
      _needsPermission = false;
      _status = 'Ready. Confirm in Android\'s installer; Encore restarts on the new version.';
    });
    try {
      await installUpdate(f);
    } catch (e) {
      if (mounted) setState(() => _status = "Couldn't open the installer: $e");
    }
  }

  String? _command; // an RPM install: the dnf command to run

  Future<void> _installDesktop(File f) async {
    if (!await canInstallUpdates()) {
      // installed by the system (RPM): dnf does it, with your password
      final url = widget.u.rpmUrl;
      setState(() {
        _command = url.isEmpty ? null : 'sudo dnf install $url';
        _status = url.isEmpty
            ? 'Encore was installed by the system. Get the new version from the release page.'
            : 'Encore was installed with dnf. Run this in a terminal to update (it asks for your password):';
      });
      return;
    }
    setState(() => _status = 'Installing…');
    try {
      await installUpdate(f);
      if (mounted) setState(() => _status = 'Done. Encore restarts on the new version.');
      await Future.delayed(const Duration(milliseconds: 800));
      await quitApp();
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = "Couldn't install the update: $e";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final downloading = _file == null && !_failed;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Updating to ${widget.u.version}', style: t.titleLarge),
            const SizedBox(height: 16),
            if (downloading) LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            if (downloading) const SizedBox(height: 12),
            Text(downloading ? '${(_progress * 100).round()}%' : _status),
            if (_command != null) ...[
              const SizedBox(height: 12),
              SelectableText(_command!, style: t.bodyMedium?.copyWith(fontFamily: 'monospace')),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_command != null)
                  TextButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _command!));
                      toast(context, 'Copied');
                    },
                    child: const Text('Copy'),
                  ),
                if (_failed || _command != null)
                  TextButton(
                    onPressed: () => openUrl(widget.u.pageUrl).catchError((_) {}),
                    child: const Text('Open the release page'),
                  ),
                TextButton(onPressed: () => Navigator.pop(context), child: Text(downloading ? 'Cancel' : 'Close')),
                if (_failed) FilledButton(onPressed: _download, child: const Text('Try again')),
                if (_needsPermission) FilledButton(onPressed: allowInstalls, child: const Text('Allow')),
                if (_file != null && !_needsPermission && !_failed && _command == null && !isDesktop)
                  FilledButton(onPressed: _install, child: const Text('Install')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings' "Check for updates now".
Future<void> checkForUpdatesNow(BuildContext context) async {
  toast(context, 'Checking for updates…');
  try {
    final u = await fetchUpdate();
    await prefs.setInt('updateCheckedAt', DateTime.now().millisecondsSinceEpoch);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (u == null) {
      toast(context, 'Encore $appVersion is the newest version');
    } else {
      await showUpdateDialog(context, u, fromCheck: true);
    }
  } catch (e) {
    if (context.mounted) toast(context, "Couldn't check for updates: $e");
  }
}
