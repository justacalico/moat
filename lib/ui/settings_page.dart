import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/picker.dart';
import '../services/settings.dart';
import '../theme.dart';
import 'widgets/sheets.dart';

/// Grouped settings: appearance, security, sync and data.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Group(
            title: 'Appearance',
            children: [
              _ThemeModeTile(),
              _AccentTile(),
              _Tile(
                icon: state.settings.gridView
                    ? Icons.grid_view_outlined
                    : Icons.view_agenda_outlined,
                title: 'Note list',
                subtitle: state.settings.gridView ? 'Grid' : 'List',
                trailing: Switch(
                  value: state.settings.gridView,
                  onChanged: state.setGridView,
                ),
              ),
              _Tile(
                icon: Icons.density_medium,
                title: 'Density',
                subtitle: state.settings.density == ListDensity.compact
                    ? 'Compact'
                    : 'Comfortable',
                trailing: Switch(
                  value: state.settings.density == ListDensity.compact,
                  onChanged: (v) => state.setDensity(
                      v ? ListDensity.compact : ListDensity.comfortable),
                ),
              ),
            ],
          ),
          _Group(
            title: 'Security',
            children: [
              _VaultTile(),
              if (state.vaultService.hasVault) ...[
                _Tile(
                  icon: Icons.timer_outlined,
                  title: 'Auto-lock',
                  subtitle: _autoLockLabel(state.settings.autoLockSeconds),
                  onTap: () => _pickAutoLock(context),
                ),
                if (!state.isWeb)
                  _BiometricTile(),
                _Tile(
                  icon: Icons.lock_clock_outlined,
                  title: 'Require unlock at launch',
                  trailing: Switch(
                    value: state.settings.lockOnStart,
                    onChanged: (v) => state.settings.lockOnStart = v,
                  ),
                ),
                _Tile(
                  icon: Icons.lock_outline,
                  title: 'Lock now',
                  onTap: state.vaultService.isUnlocked
                      ? state.lockVault
                      : null,
                ),
              ],
            ],
          ),
          if (!state.isWeb)
            _Group(
              title: 'Sync',
              children: [
                _Tile(
                  icon: Icons.sync,
                  title: 'Local sync',
                  subtitle: 'Find and pair devices on this network',
                  trailing: Switch(
                    value: state.settings.syncEnabled,
                    onChanged: state.setSyncEnabled,
                  ),
                ),
                _Tile(
                  icon: Icons.badge_outlined,
                  title: 'Device name',
                  subtitle: state.deviceName,
                  onTap: () async {
                    final name = await showTextInputDialog(
                      context,
                      title: 'Device name',
                      initial: state.settings.deviceName.isEmpty
                          ? ''
                          : state.deviceName,
                    );
                    if (name != null) await state.setDeviceName(name);
                  },
                ),
              ],
            ),
          _Group(
            title: 'Data',
            children: [
              _Tile(
                icon: Icons.upload_outlined,
                title: 'Export backup',
                subtitle: 'All notes and folders as JSON',
                onTap: () => _export(context),
              ),
              _Tile(
                icon: Icons.download_outlined,
                title: 'Import backup',
                onTap: () => _import(context),
              ),
              _Tile(
                icon: Icons.delete_forever_outlined,
                title: 'Empty trash',
                subtitle: '${state.notesInTrash.length} notes',
                onTap: () => confirmEmptyTrash(context),
              ),
            ],
          ),
          _Group(
            title: 'About',
            children: [
              _Tile(
                icon: Icons.info_outline,
                title: 'Moat',
                subtitle: 'Local-first encrypted notes · AGPL-3.0',
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Moat',
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _autoLockLabel(int seconds) => switch (seconds) {
        0 => 'Never',
        < 60 => '$seconds seconds',
        < 3600 => '${seconds ~/ 60} minutes',
        _ => '${seconds ~/ 3600} hour${seconds >= 7200 ? 's' : ''}',
      };

  Future<void> _pickAutoLock(BuildContext context) async {
    final state = context.read<AppState>();
    const choices = [60, 300, 900, 3600, 0];
    final labels = ['1 minute', '5 minutes', '15 minutes', '1 hour', 'Never'];
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Lock vault after')),
            for (var i = 0; i < choices.length; i++)
              ListTile(
                title: Text(labels[i]),
                trailing: state.settings.autoLockSeconds == choices[i]
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, choices[i]),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      state.settings.autoLockSeconds = picked;
      state.touch();
    }
  }

  Future<void> _export(BuildContext context) async {
    final state = context.read<AppState>();
    try {
      final path = await state.exportBackup();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Backup written to $path')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _import(BuildContext context) async {
    final state = context.read<AppState>();
    final path = await PickService().pickBackupFile();
    if (path == null || !context.mounted) return;
    try {
      final result = await state.importBackup(path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Imported ${result.notes} notes, ${result.folders} folders')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Import failed: $e')));
      }
    }
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Text(title.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  letterSpacing: 0.6,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
        ),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  const Divider(height: 1, indent: 52),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20),
      title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
      subtitle:
          subtitle == null ? null : Text(subtitle!),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

class _ThemeModeTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListTile(
      leading: const Icon(Icons.brightness_6_outlined, size: 20),
      title: Text('Theme', style: Theme.of(context).textTheme.bodyMedium),
      trailing: SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
          ButtonSegment(value: ThemeMode.light, label: Text('Light')),
          ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
        ],
        selected: {state.settings.themeMode},
        onSelectionChanged: (s) => state.setThemeMode(s.first),
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle:
              WidgetStatePropertyAll(Theme.of(context).textTheme.labelSmall),
        ),
      ),
    );
  }
}

class _AccentTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListTile(
      leading: const Icon(Icons.palette_outlined, size: 20),
      title: Text('Accent', style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Wrap(
          spacing: 8,
          children: [
            for (final v in MoatTheme.accentChoices)
              InkWell(
                onTap: () => state.setAccent(v),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(v),
                    shape: BoxShape.circle,
                    border: state.settings.accentColor == v
                        ? Border.all(
                            color:
                                Theme.of(context).colorScheme.onSurface,
                            width: 2)
                        : null,
                  ),
                  child: state.settings.accentColor == v
                      ? const Icon(Icons.check,
                          size: 14, color: Colors.white)
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _VaultTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final vault = state.vaultService;
    return ListTile(
      leading: const Icon(Icons.key_outlined, size: 20),
      title: Text('Vault passphrase',
          style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Text(vault.hasVault
          ? (vault.isUnlocked ? 'Set · unlocked' : 'Set · locked')
          : 'Not set'),
      onTap: () => _edit(context),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final state = context.read<AppState>();
    final vault = state.vaultService;
    if (!vault.hasVault) {
      await _setPassphrase(context, isChange: false);
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Change passphrase'),
              onTap: () => Navigator.pop(context, 'change'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text('Remove vault',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
              subtitle: const Text('Decrypts all locked notes'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'change') {
      if (!vault.isUnlocked) {
        final ok = await showUnlockSheet(context);
        if (!ok || !context.mounted) return;
      }
      await _setPassphrase(context, isChange: true);
    } else if (choice == 'remove') {
      if (!vault.isUnlocked) {
        final ok = await showUnlockSheet(context);
        if (!ok || !context.mounted) return;
      }
      final ok = await showConfirmDialog(
        context,
        title: 'Remove vault?',
        message: 'All locked notes will be decrypted.',
        confirmLabel: 'Remove',
      );
      if (ok) await state.removeVault();
    }
  }

  Future<void> _setPassphrase(BuildContext context,
      {required bool isChange}) async {
    final controller = TextEditingController();
    final confirm = TextEditingController();
    final state = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isChange ? 'Change passphrase' : 'Set vault passphrase'),
        content: PassphraseField(
          controller: controller,
          confirmController: confirm,
          showConfirm: true,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.length < 4 ||
                  controller.text != confirm.text) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'Passphrases must match (4+ characters)')));
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (isChange) {
        await state.changeVaultPassphrase(controller.text);
      } else {
        await state.setVaultPassphrase(controller.text);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Vault passphrase saved')));
      }
    }
  }
}

class _BiometricTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return FutureBuilder<bool>(
      future: state.biometric.isAvailable,
      builder: (context, snap) {
        if (snap.data != true) return const SizedBox.shrink();
        return _Tile(
          icon: Icons.fingerprint,
          title: 'Biometric unlock',
          trailing: Switch(
            value: state.settings.biometricUnlock,
            onChanged: (v) => state.settings.biometricUnlock = v,
          ),
        );
      },
    );
  }
}
