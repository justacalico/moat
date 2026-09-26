import 'clock.dart';

/// Where a note lives in the list. Trash is a soft-delete state; archived
/// notes hide from the default list but stay searchable.
enum NoteSection { active, archived, trash }

/// One encrypted blob holding both title and body of a locked note.
class LockedPayload {
  const LockedPayload({
    required this.ciphertext,
    required this.nonce,
    required this.wrappedKey,
    required this.keyNonce,
  });

  final String ciphertext;
  final String nonce;
  final String wrappedKey;
  final String keyNonce;

  Map<String, dynamic> toJson() => {
        'ciphertext': ciphertext,
        'nonce': nonce,
        'wrappedKey': wrappedKey,
        'keyNonce': keyNonce,
      };

  factory LockedPayload.fromJson(Map<String, dynamic> json) => LockedPayload(
        ciphertext: json['ciphertext'] as String,
        nonce: json['nonce'] as String,
        wrappedKey: json['wrappedKey'] as String,
        keyNonce: json['keyNonce'] as String,
      );
}

/// A single prior version of a note's text, kept for restore.
class Revision {
  const Revision({required this.title, required this.body, required this.savedAt});

  final String title;
  final String body;
  final DateTime savedAt;

  Map<String, dynamic> toJson() => {
        'title': title,
        'body': body,
        'savedAt': savedAt.toIso8601String(),
      };

  factory Revision.fromJson(Map<String, dynamic> json) => Revision(
        title: json['title'] as String,
        body: json['body'] as String,
        savedAt: DateTime.parse(json['savedAt'] as String),
      );
}

class Note {
  Note({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.clock,
    this.folderId = '',
    this.tags = const [],
    this.colorIndex = -1,
    this.pinned = false,
    this.archived = false,
    this.deleted = false,
    this.locked = false,
    this.lockedPayload,
    this.revisions = const [],
  });

  final String id;
  String title;
  String body;
  String folderId;
  List<String> tags;
  int colorIndex;
  bool pinned;
  bool archived;
  bool deleted;
  bool locked;
  LockedPayload? lockedPayload;
  List<Revision> revisions;
  DateTime createdAt;
  DateTime updatedAt;
  Map<String, int> clock;

  static const maxRevisions = 20;

  NoteSection get section => deleted
      ? NoteSection.trash
      : archived
          ? NoteSection.archived
          : NoteSection.active;

  int get wordCount {
    final text = body.trim();
    if (text.isEmpty) return 0;
    return text.split(RegExp(r'\s+')).length;
  }

  /// Estimated minutes to read at 200 wpm, minimum 1 when there is text.
  int get readingMinutes => wordCount == 0 ? 0 : (wordCount / 200).ceil();

  void pushRevision() {
    revisions = [
      ...revisions,
      Revision(title: title, body: body, savedAt: updatedAt),
    ];
    if (revisions.length > maxRevisions) {
      revisions = revisions.sublist(revisions.length - maxRevisions);
    }
  }

  /// Returns true when [other] is strictly newer than this replica.
  bool isDominatedBy(Note other) =>
      Clock.compare(clock, other.clock) == ClockOrder.dominated;

  /// Returns true when neither replica contains the other's edits.
  bool conflictsWith(Note other) =>
      Clock.compare(clock, other.clock) == ClockOrder.concurrent;

  Note copy() => Note.fromJson(toJson());

  /// A detached copy used to preserve the losing side of a sync conflict.
  Note asConflictCopy(String newId) {
    final copy = this.copy();
    return Note(
      id: newId,
      title: '$title (conflict)',
      body: copy.body,
      createdAt: copy.createdAt,
      updatedAt: copy.updatedAt,
      clock: Map<String, int>.from(copy.clock),
      folderId: copy.folderId,
      tags: List<String>.from(copy.tags),
      colorIndex: copy.colorIndex,
      pinned: copy.pinned,
      archived: copy.archived,
      deleted: copy.deleted,
      locked: copy.locked,
      lockedPayload: copy.lockedPayload,
      revisions: List<Revision>.from(copy.revisions),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'folderId': folderId,
        'tags': tags,
        'colorIndex': colorIndex,
        'pinned': pinned,
        'archived': archived,
        'deleted': deleted,
        'locked': locked,
        'lockedPayload': lockedPayload?.toJson(),
        'revisions': revisions.map((r) => r.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'clock': clock,
      };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        folderId: json['folderId'] as String? ?? '',
        tags: (json['tags'] as List? ?? []).cast<String>(),
        colorIndex: json['colorIndex'] as int? ?? -1,
        pinned: json['pinned'] as bool? ?? false,
        archived: json['archived'] as bool? ?? false,
        deleted: json['deleted'] as bool? ?? false,
        locked: json['locked'] as bool? ?? false,
        lockedPayload: json['lockedPayload'] == null
            ? null
            : LockedPayload.fromJson(
                (json['lockedPayload'] as Map).cast<String, dynamic>()),
        revisions: (json['revisions'] as List? ?? [])
            .map((r) => Revision.fromJson((r as Map).cast<String, dynamic>()))
            .toList(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        clock: (json['clock'] as Map? ?? {}).cast<String, int>(),
      );
}
