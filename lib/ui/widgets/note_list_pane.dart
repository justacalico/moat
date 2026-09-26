import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/note.dart';
import '../../services/settings.dart';
import '../editor_page.dart';
import 'empty_state.dart';
import 'note_card.dart';

/// The searchable, sortable note list — used standalone (compact) and as the
/// middle column of the wide layout.
class NoteListPane extends StatefulWidget {
  const NoteListPane({super.key, this.embedded = false});

  /// Embedded = rendered inside the wide layout (no scaffold chrome).
  final bool embedded;

  @override
  State<NoteListPane> createState() => _NoteListPaneState();
}

class _NoteListPaneState extends State<NoteListPane> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openNote(BuildContext context, AppState state, Note note) {
    state.selectNote(note.id);
    if (!widget.embedded) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
            builder: (_) => EditorPage(noteId: note.id)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final notes = state.visibleNotes;
    final selection = state.selectionMode;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: state.setQuery,
                  decoration: InputDecoration(
                    hintText: 'Search notes',
                    prefixIcon:
                        const Icon(Icons.search, size: 20),
                    suffixIcon: state.query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              state.setQuery('');
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<NoteSort>(
                icon: const Icon(Icons.sort, size: 20),
                tooltip: 'Sort',
                initialValue: state.settings.sort,
                onSelected: state.setSort,
                itemBuilder: (context) => const [
                  PopupMenuItem(
                      value: NoteSort.updated,
                      child: Text('Last edited')),
                  PopupMenuItem(
                      value: NoteSort.created,
                      child: Text('Date created')),
                  PopupMenuItem(
                      value: NoteSort.title, child: Text('Title')),
                ],
              ),
              IconButton(
                icon: Icon(
                    state.settings.gridView
                        ? Icons.view_agenda_outlined
                        : Icons.grid_view_outlined,
                    size: 20),
                tooltip: 'Toggle view',
                onPressed: () =>
                    state.setGridView(!state.settings.gridView),
              ),
            ],
          ),
        ),
        if (state.allTags.isNotEmpty && !selection)
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final tag in state.allTags)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(tag),
                      selected: state.tagFilter == tag,
                      onSelected: (_) => state.setTagFilter(tag),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: notes.isEmpty
              ? EmptyState(
                  icon: switch (state.section) {
                    NoteSection.trash => Icons.delete_outline,
                    NoteSection.archived => Icons.archive_outlined,
                    NoteSection.active => Icons.note_outlined,
                  },
                  title: state.query.isNotEmpty
                      ? 'No matches'
                      : switch (state.section) {
                          NoteSection.trash => 'Trash is empty',
                          NoteSection.archived => 'No archived notes',
                          NoteSection.active => 'No notes yet',
                        },
                  subtitle: state.query.isNotEmpty
                      ? 'Try a different search'
                      : null,
                )
              : state.settings.gridView
                  ? GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 240,
                        mainAxisExtent: 120,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemCount: notes.length,
                      itemBuilder: (context, i) =>
                          _card(context, state, notes[i], compact: true),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      itemCount: notes.length,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _card(context, state, notes[i]),
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, AppState state, Note note,
      {bool compact = false}) {
    final selecting = state.selectionMode;
    return NoteCard(
      note: note,
      compact: compact || state.settings.density == ListDensity.compact,
      selected: state.selectedNoteId == note.id,
      checked: selecting ? state.selection.contains(note.id) : null,
      onTap: () {
        if (selecting) {
          state.toggleSelection(note.id);
        } else {
          _openNote(context, state, note);
        }
      },
      onLongPress: () {
        if (!selecting) state.toggleSelection(note.id);
      },
    );
  }
}
