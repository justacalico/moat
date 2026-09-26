import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import '../theme.dart';
import 'settings_page.dart';
import 'sync_page.dart';
import 'widgets/sheets.dart';

/// The navigation column: sections, folders, tags, vault status, sync +
/// settings entries. Used as the wide-layout rail and as the compact drawer.
class SideRail extends StatelessWidget {
  const SideRail({super.key, this.inDrawer = false});

  final bool inDrawer;

  void _closeDrawer(BuildContext context) {
    if (inDrawer) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
            child: Row(
              children: [
                Icon(Icons.shield_outlined,
                    color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 8),
                Text('Moat',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                if (state.vaultService.hasVault)
                  IconButton(
                    icon: Icon(
                      state.vaultService.isUnlocked
                          ? Icons.lock_open
                          : Icons.lock_outline,
                      size: 18,
                    ),
                    tooltip: state.vaultService.isUnlocked
                        ? 'Lock vault'
                        : 'Unlock vault',
                    onPressed: () {
                      if (state.vaultService.isUnlocked) {
                        state.lockVault();
                      } else {
                        showUnlockSheet(context);
                      }
                    },
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                _SectionHeader(label: 'Library', onAdd: null),
                _NavTile(
                  icon: Icons.notes,
                  label: 'All notes',
                  selected: state.section == NoteSection.active &&
                      state.folderFilter.isEmpty &&
                      state.tagFilter.isEmpty,
                  onTap: () {
                    state.setSection(NoteSection.active);
                    state.setFolderFilter('');
                    _closeDrawer(context);
                  },
                ),
                _NavTile(
                  icon: Icons.archive_outlined,
                  label: 'Archive',
                  selected: state.section == NoteSection.archived,
                  onTap: () {
                    state.setSection(NoteSection.archived);
                    _closeDrawer(context);
                  },
                ),
                _NavTile(
                  icon: Icons.delete_outline,
                  label: 'Trash',
                  selected: state.section == NoteSection.trash,
                  badge: state.notesInTrash.isEmpty
                      ? null
                      : '${state.notesInTrash.length}',
                  onTap: () {
                    state.setSection(NoteSection.trash);
                    _closeDrawer(context);
                  },
                ),
                const SizedBox(height: 12),
                _SectionHeader(
                  label: 'Folders',
                  onAdd: () async {
                    final name = await showTextInputDialog(context,
                        title: 'New folder', hint: 'Folder name');
                    if (name != null && name.isNotEmpty) {
                      state.createFolder(name);
                    }
                  },
                  onManage: () => showManageFolders(context),
                ),
                if (state.folders.isEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text('No folders',
                        style: theme.textTheme.bodySmall),
                  )
                else
                  for (final f in state.folders)
                    _NavTile(
                      icon: Icons.folder_outlined,
                      iconColor: f.colorIndex >= 0
                          ? MoatTheme.folderColor(f.colorIndex)
                          : null,
                      label: f.name,
                      selected: state.folderFilter == f.id,
                      badge: '${state.noteCountInFolder(f.id)}',
                      onTap: () {
                        state.setFolderFilter(f.id);
                        _closeDrawer(context);
                      },
                    ),
                const SizedBox(height: 12),
                _SectionHeader(label: 'Tags', onAdd: null),
                if (state.allTags.isEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text('No tags', style: theme.textTheme.bodySmall),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final tag in state.allTags)
                          FilterChip(
                            label: Text(tag),
                            selected: state.tagFilter == tag,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) {
                              state.setTagFilter(tag);
                            },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (!state.isWeb)
            _NavTile(
              icon: Icons.sync,
              label: 'Sync',
              onTap: () {
                _closeDrawer(context);
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const SyncPage()));
              },
            ),
          _NavTile(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onTap: () {
              _closeDrawer(context);
              Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const SettingsPage()));
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.onAdd, this.onManage});

  final String label;
  final VoidCallback? onAdd;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 2),
      child: Row(
        children: [
          Text(label.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  letterSpacing: 0.6,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
          const Spacer(),
          if (onManage != null)
            InkWell(
              onTap: onManage,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.more_horiz,
                    size: 16,
                    color: Theme.of(context).textTheme.bodySmall?.color),
              ),
            ),
          if (onAdd != null)
            InkWell(
              onTap: onAdd,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.add,
                    size: 16,
                    color: Theme.of(context).textTheme.bodySmall?.color),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    this.iconColor,
    this.selected = false,
    this.badge,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color? iconColor;
  final bool selected;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon,
                    size: 18,
                    color: iconColor ??
                        (selected
                            ? theme.colorScheme.primary
                            : theme.textTheme.bodySmall?.color)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color:
                          selected ? theme.colorScheme.primary : null,
                    ),
                  ),
                ),
                if (badge != null)
                  Text(badge!,
                      style: theme.textTheme.labelSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
