import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import 'editor_page.dart';
import 'side_rail.dart';
import 'widgets/note_list_pane.dart';
import 'widgets/sheets.dart';

/// Root scaffold: compact phones get a drawer + pushed editor route, wide
/// windows get a three-pane layout. Both read the same AppState — resizing
/// only swaps widgets, never data.
class NotesHomePage extends StatelessWidget {
  const NotesHomePage({super.key});

  void _newNote(BuildContext context) {
    final state = context.read<AppState>();
    final note = state.createNote(folderId: state.folderFilter);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (!wide) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => EditorPage(noteId: note.id)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        if (wide) {
          return Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 260, child: SideRail()),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 320,
                  child: Column(
                    children: [
                      _SelectionBar(),
                      const Expanded(
                          child: NoteListPane(embedded: true)),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: state.selectedNoteId == null
                      ? const _EditorPlaceholder()
                      : EditorPage(
                          key: ValueKey(state.selectedNoteId),
                          noteId: state.selectedNoteId!,
                          embedded: true,
                        ),
                ),
              ],
            ),
            floatingActionButton: FloatingActionButton(
              heroTag: 'new-note-wide',
              onPressed: () => _newNote(context),
              child: const Icon(Icons.add),
            ),
          );
        }
        return Scaffold(
          appBar: state.selectionMode
              ? AppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: state.clearSelection,
                  ),
                  title: Text('${state.selection.length} selected'),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.push_pin_outlined),
                      tooltip: 'Pin',
                      onPressed: state.batchPin,
                    ),
                    IconButton(
                      icon: const Icon(Icons.archive_outlined),
                      tooltip: 'Archive',
                      onPressed: state.batchArchive,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Trash',
                      onPressed: state.batchMoveToTrash,
                    ),
                  ],
                )
              : null,
          drawer: const Drawer(
            width: 300,
            child: SideRail(inDrawer: true),
          ),
          body: const Column(
            children: [
              _CompactHeader(),
              Expanded(child: NoteListPane()),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            heroTag: 'new-note-compact',
            onPressed: () => _newNote(context),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }
}

class _CompactHeader extends StatelessWidget {
  const _CompactHeader();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final title = switch (state.section) {
      NoteSection.active => state.folderFilter.isNotEmpty
          ? state.folderById(state.folderFilter)?.name ?? 'Folder'
          : 'Moat',
      NoteSection.archived => 'Archive',
      NoteSection.trash => 'Trash',
    };
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            if (state.section == NoteSection.trash &&
                state.notesInTrash.isNotEmpty)
              TextButton(
                onPressed: () => confirmEmptyTrash(context),
                child: const Text('Empty'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Wide-layout batch action bar — only occupies space while selecting.
class _SelectionBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.selectionMode) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: state.clearSelection,
            ),
            Text('${state.selection.length}'),
            const Spacer(),
            IconButton(
                icon: const Icon(Icons.push_pin_outlined, size: 18),
                onPressed: state.batchPin),
            IconButton(
                icon: const Icon(Icons.archive_outlined, size: 18),
                onPressed: state.batchArchive),
            IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: state.batchMoveToTrash),
          ],
        ),
      ),
    );
  }
}

class _EditorPlaceholder extends StatelessWidget {
  const _EditorPlaceholder();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_note, size: 40, color: muted),
          const SizedBox(height: 8),
          Text('Select a note or start a new one',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: muted)),
        ],
      ),
    );
  }
}
