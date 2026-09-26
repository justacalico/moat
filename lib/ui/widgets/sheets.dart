import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/note.dart';
import '../../theme.dart';
import '../../util/format.dart';

/// Shared dialogs and sheets so every screen asks for input the same way.

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String? hint,
  String initial = '',
  String confirmLabel = 'Save',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

/// A passphrase entry field with optional confirmation and strength hint.
class PassphraseField extends StatefulWidget {
  const PassphraseField({
    super.key,
    this.controller,
    this.confirmController,
    this.autofocus = false,
    this.errorText,
    this.onSubmitted,
    this.showConfirm = false,
  });

  final TextEditingController? controller;
  final TextEditingController? confirmController;
  final bool autofocus;
  final String? errorText;
  final ValueChanged<String>? onSubmitted;
  final bool showConfirm;

  @override
  State<PassphraseField> createState() => _PassphraseFieldState();
}

class _PassphraseFieldState extends State<PassphraseField> {
  bool _obscure = true;
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  late final TextEditingController _confirm =
      widget.confirmController ?? TextEditingController();

  String? get _strengthHint {
    if (!widget.showConfirm) return null;
    final v = _controller.text;
    if (v.isEmpty) return null;
    if (v.length < 8) return 'Weak — use 8+ characters';
    if (v.length < 12) return 'Okay — longer is stronger';
    return 'Strong';
  }

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      TextField(
        controller: _controller,
        autofocus: widget.autofocus,
        obscureText: _obscure,
        onChanged: (_) => setState(() {}),
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          hintText: 'Vault passphrase',
          errorText: widget.errorText,
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                size: 20),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      ),
    ];
    if (widget.showConfirm) {
      fields
        ..add(const SizedBox(height: 10))
        ..add(TextField(
          controller: _confirm,
          obscureText: _obscure,
          onChanged: (_) => setState(() {}),
          onSubmitted: widget.onSubmitted,
          decoration: const InputDecoration(hintText: 'Confirm passphrase'),
        ));
      if (_strengthHint != null) {
        fields.add(Padding(
          padding: const EdgeInsets.only(top: 8, left: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(_strengthHint!,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ));
      }
    }
    return Column(mainAxisSize: MainAxisSize.min, children: fields);
  }
}

/// Asks for the vault passphrase and unlocks. Returns true on success.
Future<bool> showUnlockSheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _UnlockSheet(),
  ).then((v) => v ?? false);
}

class _UnlockSheet extends StatefulWidget {
  const _UnlockSheet();

  @override
  State<_UnlockSheet> createState() => _UnlockSheetState();
}

class _UnlockSheetState extends State<_UnlockSheet> {
  final _controller = TextEditingController();
  bool _busy = false;
  bool _failed = false;

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    final ok = await context.read<AppState>().unlockVault(_controller.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _failed = true;
      });
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Unlock vault',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Locked notes stay encrypted until you unlock.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          PassphraseField(
            controller: _controller,
            autofocus: true,
            errorText: _failed ? 'Wrong passphrase' : null,
            onSubmitted: (_) => _unlock(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _unlock,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Unlock'),
          ),
        ],
      ),
    );
  }
}

/// Folder picker — moves a note into a folder or out of one.
Future<void> showFolderPicker(BuildContext context, Note note) {
  final state = context.read<AppState>();
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Move to folder')),
          ListTile(
            leading: const Icon(Icons.note_outlined),
            title: const Text('No folder'),
            trailing: note.folderId.isEmpty ? const Icon(Icons.check) : null,
            onTap: () {
              state.setFolder(note, '');
              Navigator.pop(context);
            },
          ),
          for (final f in state.folders)
            ListTile(
              leading: Icon(Icons.folder_outlined,
                  color: f.colorIndex >= 0
                      ? MoatTheme.folderColor(f.colorIndex)
                      : null),
              title: Text(f.name),
              trailing:
                  note.folderId == f.id ? const Icon(Icons.check) : null,
              onTap: () {
                state.setFolder(note, f.id);
                Navigator.pop(context);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Tag editor sheet — add/remove tags on a note.
Future<void> showTagEditor(BuildContext context, Note note) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _TagSheet(note: note),
  );
}

class _TagSheet extends StatefulWidget {
  const _TagSheet({required this.note});
  final Note note;

  @override
  State<_TagSheet> createState() => _TagSheetState();
}

class _TagSheetState extends State<_TagSheet> {
  final _controller = TextEditingController();

  void _add() {
    final tag = _controller.text.trim();
    if (tag.isEmpty) return;
    final state = context.read<AppState>();
    if (!widget.note.tags.contains(tag)) {
      state.setTags(widget.note, [...widget.note.tags, tag]);
    }
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final note = state.noteById(widget.note.id) ?? widget.note;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tags', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in note.tags)
                InputChip(
                  label: Text(tag),
                  onDeleted: () => state.setTags(
                      note, note.tags.where((t) => t != tag).toList()),
                ),
              if (note.tags.isEmpty)
                Text('No tags yet',
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(hintText: 'Add a tag'),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                  onPressed: _add, icon: const Icon(Icons.add)),
            ],
          ),
          if (state.allTags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final tag in state.allTags.where(
                    (t) => !note.tags.contains(t)))
                  ActionChip(
                    label: Text(tag),
                    onPressed: () =>
                        state.setTags(note, [...note.tags, tag]),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Color picker row for notes.
Future<void> showColorPicker(BuildContext context, Note note) {
  final state = context.read<AppState>();
  final brightness = Theme.of(context).brightness;
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Note color',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _ColorDot(
                  color: null,
                  selected: note.colorIndex < 0,
                  onTap: () {
                    state.setColor(note, -1);
                    Navigator.pop(context);
                  },
                ),
                for (var i = 0; i < MoatTheme.noteColorsLight.length; i++)
                  _ColorDot(
                    color: MoatTheme.noteColor(i, brightness),
                    selected: note.colorIndex == i,
                    onTap: () {
                      state.setColor(note, i);
                      Navigator.pop(context);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({this.color, required this.selected, required this.onTap});
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isNone = color == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color ?? Theme.of(context).scaffoldBackgroundColor,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).dividerColor,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: isNone ? const Icon(Icons.format_clear, size: 18) : null,
      ),
    );
  }
}

/// Simple "are you sure" helper for emptying trash.
Future<void> confirmEmptyTrash(BuildContext context) async {
  final state = context.read<AppState>();
  final count = state.notesInTrash.length;
  if (count == 0) return;
  final ok = await showConfirmDialog(
    context,
    title: 'Empty trash?',
    message: '$count note${count == 1 ? '' : 's'} will be deleted forever.',
  );
  if (ok) await state.emptyTrash();
}

/// Folder management sheet (create/rename/delete).
Future<void> showManageFolders(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _ManageFoldersSheet(),
  );
}

class _ManageFoldersSheet extends StatelessWidget {
  const _ManageFoldersSheet();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('Folders'),
            trailing: IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: () async {
                final name = await showTextInputDialog(context,
                    title: 'New folder', hint: 'Folder name');
                if (name != null && name.isNotEmpty) {
                  state.createFolder(name);
                }
              },
            ),
          ),
          const Divider(),
          for (final f in state.folders)
            ListTile(
              leading: Icon(Icons.folder_outlined,
                  color: f.colorIndex >= 0
                      ? MoatTheme.folderColor(f.colorIndex)
                      : null),
              title: Text(f.name),
              subtitle:
                  Text('${state.noteCountInFolder(f.id)} notes'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () async {
                      final name = await showTextInputDialog(context,
                          title: 'Rename folder', initial: f.name);
                      if (name != null && name.isNotEmpty) {
                        state.renameFolder(f, name);
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () async {
                      final ok = await showConfirmDialog(
                        context,
                        title: 'Delete "${f.name}"?',
                        message:
                            'Notes inside stay in All Notes.',
                        confirmLabel: 'Delete folder',
                      );
                      if (ok) await state.deleteFolder(f);
                    },
                  ),
                ],
              ),
              onTap: () {
                state.setFolderFilter(f.id);
                Navigator.pop(context);
              },
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// Revisions history for a note.
Future<void> showRevisions(BuildContext context, Note note) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _RevisionsSheet(note: note),
  );
}

class _RevisionsSheet extends StatelessWidget {
  const _RevisionsSheet({required this.note});
  final Note note;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final current = state.noteById(note.id) ?? note;
    final revisions = current.revisions.reversed.toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scroll) => Column(
        children: [
          const ListTile(title: Text('History')),
          const Divider(),
          Expanded(
            child: revisions.isEmpty
                ? const Center(child: Text('No earlier versions'))
                : ListView.builder(
                    controller: scroll,
                    itemCount: revisions.length,
                    itemBuilder: (context, i) {
                      final rev = revisions[i];
                      return ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(
                          rev.title.isEmpty ? 'Untitled' : rev.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${fullTime(rev.savedAt)} · '
                          '${previewLine(rev.body, max: 60)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: TextButton(
                          onPressed: () async {
                            final ok = await showConfirmDialog(
                              context,
                              title: 'Restore this version?',
                              message:
                                  'The current text is kept in history.',
                              confirmLabel: 'Restore',
                              destructive: false,
                            );
                            if (ok && context.mounted) {
                              await state.restoreRevision(current, rev);
                              if (context.mounted) Navigator.pop(context);
                            }
                          },
                          child: const Text('Restore'),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
