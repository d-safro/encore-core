import '../../playback/handler.dart';
import '../widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../data/account.dart';
import '../../data/local_link.dart';
import '../../data/pairing.dart';
import '../../data/subsonic.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.adding = false});
  final bool adding; // another server, from Settings (the current one stays saved)
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  void _safeSetState(VoidCallback f) {
    if (mounted) setState(f);
  }

  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    _safeSetState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountProvider.notifier).signIn(
        _server.text,
        _user.text,
        _pass.text,
        beforeSwitch: audioHandler.leaveServer,
      );
      await audioHandler.enterServer();
      if (widget.adding && mounted) Navigator.of(context).pop();
    } catch (e) {
      _safeSetState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) _safeSetState(() => _busy = false);
    }
  }

  /// Sign in with a code typed on a device that is signed in already (data/pairing.dart).
  Future<void> _withPhone() async {
    if (_server.text.trim().isEmpty) {
      _safeSetState(() => _error = 'Type your server address first (the one your phone uses, or this network\'s)');
      return;
    }
    _safeSetState(() => _error = null);
    final login = await showDialog<PairedLogin>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => _PairDialog(server: _server.text),
    );
    if (login == null || !mounted) return;
    _safeSetState(() => _busy = true);
    try {
      // the address your phone uses; the one typed here if this computer can only reach the server that way
      var server = login.server;
      try {
        await ref.read(accountProvider.notifier).signIn(server, login.user, login.pass, beforeSwitch: audioHandler.leaveServer);
      } catch (_) {
        server = serverBase(_server.text);
        await ref.read(accountProvider.notifier).signIn(server, login.user, login.pass, beforeSwitch: audioHandler.leaveServer);
      }
      if (login.localAddress.isNotEmpty) await ref.read(localAddressProvider.notifier).set(login.localAddress);
      await audioHandler.enterServer();
      if (widget.adding && mounted) Navigator.of(context).pop();
    } catch (e) {
      _safeSetState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) _safeSetState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: widget.adding ? AppBar(title: const Text('Add a server')) : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: EncoreLogo(size: 88)),
                    const SizedBox(height: 12),
                    Text('Encore', textAlign: TextAlign.center, style: t.displaySmall),
                    Text(
                      'Sign in to your Navidrome or Subsonic server',
                      textAlign: TextAlign.center,
                      style: t.bodyMedium,
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Server address',
                        hintText: 'https://music.example.com',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _user,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pass,
                      obscureText: _hide,
                      textInputAction: TextInputAction.go,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _hide ? 'Show password' : 'Hide password',
                          icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => _safeSetState(() => _hide = !_hide),
                        ),
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Sign in'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.phonelink_lock_rounded),
                      label: Text(isDesktop ? 'Sign in with your phone' : 'Sign in with another device'),
                      onPressed: _busy ? null : _withPhone,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Type the server address, then get a code to type on a device that\'s signed in '
                        '(Settings › Sign in another device). Needs Conductor or music-lookup.',
                        textAlign: TextAlign.center,
                        style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the code and waits until it's typed on the other device; pops the login it handed over.
class _PairDialog extends StatefulWidget {
  const _PairDialog({required this.server});
  final String server;
  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  PairingCode? _code;
  String? _error;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _code = null;
      _error = null;
    });
    try {
      final code = await startPairing(widget.server);
      if (_closed) return;
      setState(() => _code = code);
      final login = await waitForLogin(widget.server, code, cancelled: () => _closed);
      if (_closed) return;
      if (login == null) {
        setState(() => _error = 'The code ran out. Get a new one.');
      } else {
        Navigator.pop(context, login);
      }
    } on SubsonicException catch (e) {
      if (!_closed) setState(() => _error = e.message);
    } catch (e) {
      if (!_closed) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final code = _code;
    return AlertDialog(
      title: Text(isDesktop ? 'Sign in with your phone' : 'Sign in with another device'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null)
              Text(_error!, style: TextStyle(color: cs.error))
            else if (code == null)
              const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())
            else ...[
              Text(
                'On your ${isDesktop ? 'phone' : 'other device'}, open Encore › Settings › Sign in another device, '
                'and type:',
              ),
              const SizedBox(height: 16),
              SelectableText(code.pretty, style: t.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 4)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text(isDesktop ? 'Waiting for your phone…' : 'Waiting…', style: t.bodySmall),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_error != null) TextButton(onPressed: _start, child: const Text('New code')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}
