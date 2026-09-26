import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import '../util/format.dart';
import 'widgets/markdown_toolbar.dart';
import 'widgets/sheets.dart';

/// Note editor. [embedded] drops the app bar so it can sit in the wide
/// three-pane layout.
class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.noteId, this.embedded = false});

  final String noteId;
  final bool embedded;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  final _bodyFocus = FocusNode();
  bool _preview = false;
  String _lastSavedTitle = '';
  String _lastSavedBody = '';
  String? _loadedFor;

  @override
  void dispose() {
    _saveIfDirty();
    _titleController.dispose();
    _bodyController.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _loadIfNeeded(AppState state) {
    if (_loadedFor == widget.noteId) return;
    _loadedFor = widget.noteId;
    final note = state.noteById(widget.noteId);
    if (note == null) return;
    _lastSavedTitle = note.locked
        ? ''
        : note.title;
    _lastSavedBody = note.locked ? '' : note.body;
    _titleController.text = _lastSavedTitle;
    _bodyController.text = _lastSavedBody;
  }

  bool get _dirtyContent =>
      _titleController.text != _lastSavedTitle ||
      _bodyController.text != _lastSavedBody;

  Future<void> _saveIfDirty() async {
    if (!_dirtyContent || !mounted) return;
    final state = context.read<AppState>();
    final note = state.noteById(widget.noteId);
    if (note == null || (note.locked && !state.vaultService.isUnlocked)) {
      return;
    }
    await state.updateNote(
      note,
      title: _titleController.text,
      body: _bodyController.text,
      contentChanged: _bodyController.text != _lastSavedBody,
    );
    _lastSavedTitle = _titleController.text;
    _lastSavedBody = _bodyController.text;
  }

  Future<void> _toggleLock(BuildContext context, Note note) async {
    final state = context.read<AppState>();
    if (note.locked) {
      if (!state.vaultService.isUnlocked) {
        final ok = await showUnlockSheet(context);
        if (!ok || !context.mounted) return;
      }
      await state.unlockNote(note);
      _lastSavedTitle = note.title;
      _lastSavedBody = note.body;
      _titleController.text = note.title;
      _bodyController.text = note.body;
      setState(() {});
      return;
    }
    if (!state.vaultService.hasVault) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Set a vault passphrase in Settings first')));
      }
      return;
    }
    if (!state.vaultService.isUnlocked) {
      final ok = await showUnlockSheet(context);
      if (!ok || !context.mounted) return;
    }
    await _saveIfDirty();
    await state.lockNote(note);
    if (context.mounted) setState(() {});
  }

  Future<void> _openLocked(BuildContext context, Note note) async {
    final state = context.read<AppState>();
    if (!state.vaultService.isUnlocked) {
      final ok = await showUnlockSheet(context);
      if (!ok || !context.mounted) return;
    }
    final opened = await state.openNote(note);
    if (!context.mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Cannot decrypt — this note was locked with a different vault passphrase')));
      return;
    }
    final plain = state.displayTitle(note) == 'Untitled'
        ? ''
        : state.displayTitle(note);
    _lastSavedTitle = plain;
    _lastSavedBody = state.displayBody(note);
    _titleController.text = plain;
    _bodyController.text = _lastSavedBody;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final note = state.noteById(widget.noteId);
    if (note == null) {
      return widget.embedded
          ? const SizedBox.shrink()
          : const Scaffold(body: Center(child: Text('Note deleted')));
    }
    _loadIfNeeded(state);
    final locked = note.locked && !state.vaultService.isUnlocked;

    final body = locked
        ? _LockedBody(
            onUnlock: () => _openLocked(context, note),
            biometric: state.settings.biometricUnlock,
          )
        : _preview
            ? MarkdownBody(
                data: '# ${_titleController.text}\n\n${_bodyController.text}',
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                    .copyWith(
                  p: Theme.of(context).textTheme.bodyLarge,
                  listBullet:
                      Theme.of(context).textTheme.bodyLarge,
                ),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: TextField(
                      controller: _titleController,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                      decoration: const InputDecoration(
                        hintText: 'Title',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                      ),
                      onChanged: (_) {},
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _bodyController,
                        focusNode: _bodyFocus,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        decoration: const InputDecoration(
                          hintText: 'Start writing…',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                        ),
                        onChanged: (_) {},
                      ),
                    ),
                  ),
                ],
              );

    final metaBar = _MetaBar(note: note);

    final content = Column(
      children: [
        if (!locked)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: MarkdownToolbar(controller: _bodyController),
          ),
        Expanded(
          child: _preview || locked
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: SingleChildScrollView(child: body),
                )
              : body,
        ),
        metaBar,
      ],
    );

    final actions = <Widget>[
      if (!locked)
        IconButton(
          icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined,
              size: 20),
          tooltip: _preview ? 'Edit' : 'Preview',
          onPressed: () async {
            if (!_preview) await _saveIfDirty();
            setState(() => _preview = !_preview);
          },
        ),
      IconButton(
        icon: Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
            size: 20),
        tooltip: 'Pin',
        onPressed: () => state.togglePin(note),
      ),
      IconButton(
        icon: Icon(
            note.locked ? Icons.lock : Icons.lock_open_outlined,
            size: 20,
            color: note.locked
                ? Theme.of(context).colorScheme.primary
                : null),
        tooltip: note.locked ? 'Unlock note' : 'Lock note',
        onPressed: () => _toggleLock(context, note),
      ),
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 20),
        onSelected: (v) => _menu(context, state, note, v),
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'tags', child: Text('Tags')),
          const PopupMenuItem(value: 'folder', child: Text('Move to folder')),
          const PopupMenuItem(value: 'color', child: Text('Color')),
          const PopupMenuItem(value: 'history', child: Text('History')),
          PopupMenuItem(
              value: 'archive',
              child: Text(note.archived ? 'Unarchive' : 'Archive')),
          const PopupMenuItem(value: 'copy', child: Text('Copy text')),
          const PopupMenuItem(value: 'export', child: Text('Export .md')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    ];

    if (widget.embedded) {
      return Material(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(children: [const Spacer(), ...actions]),
            ),
            Expanded(child: content),
          ],
        ),
      );
    }
    return PopScope(
      onPopInvokedWithResult: (_, _) => _saveIfDirty(),
      child: Scaffold(
        appBar: AppBar(actions: actions),
        body: content,
      ),
    );
  }

  Future<void> _menu(
      BuildContext context, AppState state, Note note, String v) async {
    await _saveIfDirty();
    if (!context.mounted) return;
    switch (v) {
      case 'tags':
        await showTagEditor(context, note);
      case 'folder':
        await showFolderPicker(context, note);
      case 'color':
        await showColorPicker(context, note);
      case 'history':
        await showRevisions(context, note);
      case 'archive':
        await state.setArchived(note, !note.archived);
      case 'copy':
        await Clipboard.setData(ClipboardData(
            text: '${_titleController.text}\n\n${_bodyController.text}'));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Copied')));
        }
      case 'export':
        try {
          final path = await state.exportNoteMarkdown(note,
              title: _titleController.text, body: _bodyController.text);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Exported to $path')));
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Export failed: $e')));
          }
        }
      case 'delete':
        await state.moveToTrash(note);
        if (context.mounted && !widget.embedded) Navigator.pop(context);
    }
  }
}

class _LockedBody extends StatelessWidget {
  const _LockedBody({required this.onUnlock, required this.biometric});

  final VoidCallback onUnlock;
  final bool biometric;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline,
              size: 36, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text('This note is locked',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('Encrypted with your vault passphrase',
              style:
                  Theme.of(context).textTheme.bodySmall?.copyWith(color: muted)),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: onUnlock,
            icon: Icon(biometric ? Icons.fingerprint : Icons.lock_open),
            label: const Text('Unlock'),
          ),
        ],
      ),
    );
  }
}

class _MetaBar extends StatelessWidget {
  const _MetaBar({required this.note});
  final Note note;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final folder = note.folderId.isEmpty
        ? null
        : state.folderById(note.folderId)?.name;
    final words = state.displayBody(note).trim().isEmpty
        ? 0
        : state.displayBody(note).trim().split(RegExp(r'\s+')).length;
    return Container(
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(color: theme.dividerColor, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text('$words words · ${fullTime(note.updatedAt)}',
              style: theme.textTheme.labelSmall),
          const Spacer(),
          if (folder != null)
            Text(folder, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}
