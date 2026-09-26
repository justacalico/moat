import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/peer.dart';
import '../services/sync/engine.dart';
import '../util/format.dart';
import 'widgets/sheets.dart';

/// LAN sync control center: discovered peers, pairing, trusted devices and
/// the live event log. Hidden entirely on web.
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  StreamSubscription<SyncEvent>? _sub;
  final List<SyncEvent> _events = [];
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final sync = context.read<AppState>().sync;
    _events.addAll(sync?.events ?? const []);
    _sub = sync?.eventStream.listen((e) {
      if (mounted) setState(() => _events.add(e));
    });
    // Re-render once in a while so "last seen" ages.
    _ticker = Timer.periodic(
        const Duration(seconds: 5), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _pairWith(SyncPeer peer) async {
    final state = context.read<AppState>();
    try {
      await state.pairWith(peer, () => _askCode(context));
    } catch (_) {
      // Pairing errors already land in the event log.
    }
  }

  Future<String> _askCode(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Enter pairing code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'The other device is showing a 6-digit code. Type it here.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(letterSpacing: 6),
              decoration: const InputDecoration(counterText: ''),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, controller.text.trim()),
            child: const Text('Pair'),
          ),
        ],
      ),
    ).then((v) {
      if (v == null || v.isEmpty) {
        throw StateError('pairing cancelled');
      }
      return v;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sync = state.sync;
    final peers = state.peers;
    final trusted = peers.where((p) => p.paired).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('This device',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall),
                            const SizedBox(height: 2),
                            Text(
                              '${state.deviceName} · ${state.deviceId.substring(0, 8)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: state.settings.syncEnabled,
                        onChanged: state.setSyncEnabled,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Devices on the same network find each other automatically. '
                    'Pairing once with a code encrypts everything they exchange.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: state.syncNow,
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('Sync now'),
                      ),
                      const SizedBox(width: 12),
                      if (sync?.running == true)
                        Text('listening',
                            style: Theme.of(context).textTheme.bodySmall)
                      else
                        Text('off',
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Nearby devices',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          if (peers.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'No devices found. Make sure Moat is open on the other '
                  'device and both are on the same network.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < peers.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _PeerTile(
                      peer: peers[i],
                      trusted: state.isPeerTrusted(peers[i].deviceId),
                      onPair: () => _pairWith(peers[i]),
                      onUnpair: () async {
                        final ok = await showConfirmDialog(
                          context,
                          title: 'Unpair ${peers[i].name}?',
                          message:
                              'It will need a new code to sync again.',
                          confirmLabel: 'Unpair',
                        );
                        if (ok) state.unpairPeer(peers[i].deviceId);
                      },
                    ),
                  ],
                ],
              ),
            ),
          if (trusted.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('${trusted.length} paired',
                style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 20),
          Text('Activity', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Card(
            child: _events.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('Nothing yet',
                        style: Theme.of(context).textTheme.bodySmall),
                  )
                : Column(
                    children: [
                      for (final e in _events.reversed.take(50))
                        _EventTile(event: e),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.peer,
    required this.trusted,
    required this.onPair,
    required this.onUnpair,
  });

  final SyncPeer peer;
  final bool trusted;
  final VoidCallback onPair;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          peer.paired ? Icons.devices : Icons.devices_other,
          size: 16,
          color: peer.paired ? theme.colorScheme.primary : null,
        ),
      ),
      title: Text(peer.name, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        '${peer.host}:${peer.port} · seen ${relativeTime(peer.lastSeen)}',
        style: theme.textTheme.labelSmall,
      ),
      trailing: peer.paired || trusted
          ? TextButton(onPressed: onUnpair, child: const Text('Unpair'))
          : FilledButton.tonal(onPressed: onPair, child: const Text('Pair')),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});
  final SyncEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (event.kind) {
      SyncEventKind.error => theme.colorScheme.error,
      SyncEventKind.conflict => theme.colorScheme.tertiary,
      SyncEventKind.paired => theme.colorScheme.primary,
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(timeOnly(event.at),
                style: theme.textTheme.labelSmall),
          ),
          Expanded(
            child: Text(event.message,
                style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}
