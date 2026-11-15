import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/account.dart';
import '../../data/library.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false, _hide = true;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountProvider.notifier).signIn(_server.text, _user.text, _pass.text);
      ref.read(syncProvider.notifier).sync(); // build the offline copy in the background
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
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
                    Icon(Icons.graphic_eq_rounded, size: 64, color: Theme.of(context).colorScheme.primary),
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
                          icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _hide = !_hide),
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
