import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import 'home_page.dart';
import 'lock_screen.dart';
import 'widgets/sheets.dart';

/// Lets sync-layer callbacks open dialogs from anywhere.
final navigatorKey = GlobalKey<NavigatorState>();

class MoatApp extends StatelessWidget {
  const MoatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return MaterialApp(
      title: 'Moat',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: MoatTheme.light(state.settings.accentColor),
      darkTheme: MoatTheme.dark(state.settings.accentColor),
      themeMode: state.settings.themeMode,
      home: state.ready ? const AdaptiveHome() : const _Boot(),
    );
  }
}

class _Boot extends StatelessWidget {
  const _Boot();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

/// Compact (phone) and wide (desktop/tablet) shells over one AppState.
class AdaptiveHome extends StatefulWidget {
  const AdaptiveHome({super.key});

  @override
  State<AdaptiveHome> createState() => _AdaptiveHomeState();
}

class _AdaptiveHomeState extends State<AdaptiveHome> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireSyncHooks());
  }

  void _wireSyncHooks() {
    final sync = context.read<AppState>().sync;
    if (sync == null) return;
    sync.onPairRequest = (peerId, peerName) async {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return false;
      return showConfirmDialog(
        ctx,
        title: 'Pair request',
        message: '"$peerName" wants to pair with this device. '
            'Pairing lets it sync your notes.',
        confirmLabel: 'Pair',
      );
    };
    sync.onShowPairCode = (code) {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;
      showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Pairing code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Enter this code on the other device:',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              Text(
                code,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 8,
                    ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.settings.lockOnStart &&
        state.vaultService.hasVault &&
        !state.vaultService.isUnlocked) {
      return const LockScreen();
    }
    return const NotesHomePage();
  }
}
