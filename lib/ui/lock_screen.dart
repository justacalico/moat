import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'widgets/sheets.dart';

/// Full-screen vault gate shown on launch when "lock on start" is enabled.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
  }

  Future<void> _tryBiometric() async {
    final state = context.read<AppState>();
    if (!state.settings.biometricUnlock) return;
    if (!await state.biometric.isAvailable) return;
    if (await state.biometricUnlock()) {
      // Biometrics guard the prompt — the passphrase itself is still needed,
      // so a successful biometric just focuses the field.
      setState(() {});
    }
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    final ok = await context.read<AppState>().unlockVault(_controller.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !ok;
    });
    if (!ok) _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline,
                  size: 44, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('Moat is locked',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 24),
              PassphraseField(
                controller: _controller,
                autofocus: true,
                errorText: _failed ? 'Wrong passphrase' : null,
                onSubmitted: (_) => _unlock(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _unlock,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Unlock'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
