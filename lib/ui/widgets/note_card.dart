import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/note.dart';
import '../../theme.dart';
import '../../util/format.dart';

/// A note row/card in the list. Shows lock state, pin, color tint, tags.
class NoteCard extends StatelessWidget {
  const NoteCard({
    super.key,
    required this.note,
    this.selected = false,
    this.checked,
    this.onTap,
    this.onLongPress,
    this.compact = false,
  });

  final Note note;
  final bool selected;

  /// Null = not in selection mode; otherwise checkbox state.
  final bool? checked;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final tint = MoatTheme.noteColor(note.colorIndex, theme.brightness);
    final locked = note.locked;
    final unlocked = locked && state.vaultService.isUnlocked;

    return Card(
      color: tint,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: 14, vertical: compact ? 8 : 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (checked != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 10),
                  child: Icon(
                    checked!
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (note.pinned)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(Icons.push_pin,
                                size: 13,
                                color: theme.colorScheme.primary),
                          ),
                        if (locked)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              unlocked
                                  ? Icons.lock_open
                                  : Icons.lock_outline,
                              size: 13,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            state.displayTitle(note),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: locked && !unlocked
                                  ? theme.textTheme.bodySmall?.color
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(relativeTime(note.updatedAt),
                            style: theme.textTheme.labelSmall),
                      ],
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 3),
                      Text(
                        locked && !unlocked
                            ? 'Encrypted'
                            : previewLine(state.displayBody(note)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (note.tags.isNotEmpty && !compact) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        children: [
                          for (final tag in note.tags.take(4))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: theme.colorScheme
                                    .surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(tag,
                                  style: theme.textTheme.labelSmall),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
