import 'dart:async';
import 'dart:collection';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:uuid/uuid.dart';

import 'models/clock.dart';
import 'models/folder.dart';
import 'models/note.dart';
import 'models/peer.dart';
import 'services/biometric.dart';
import 'services/crypto_service.dart';
import 'services/exporter.dart';
import 'services/settings.dart';
import 'services/storage.dart';
import 'services/sync/engine.dart';
import 'services/sync/sync.dart' as platform;
import 'services/sync/sync_store.dart';
import 'services/vault.dart';
import 'util/platform_name.dart';

/// The one state object for the whole app. Created once in main() above
/// MaterialApp — resizing the window changes layout, never this.
class AppState extends ChangeNotifier implements SyncStore {
  AppState({
    required this.storage,
    required this.settings,
    CryptoService? crypto,
    VaultService? vault,
    BiometricGate? biometric,
    SyncEngine? sync,
    this.isWeb = kIsWeb,
  })  : crypto = crypto ?? CryptoService(),
        vault = vault ?? VaultService(),
        biometric = biometric ?? LocalAuthGate(),
        _syncOverride = sync;

  final Storage storage;
  final Settings settings;
  final CryptoService crypto;
  final VaultService vault;
  final BiometricGate biometric;
  final bool isWeb;
  final SyncEngine? _syncOverride;
  String? _deviceName;

  SyncEngine? _sync;

  final _uuid = const Uuid();
  final List<Note> _notes = [];
  final List<Folder> _folders = [];
  final Map<String, ({String title, String body})> _plaintext = {};
  final Map<String, SecretKey> _peerKeys = {};
  final Map<String, String> _peerNames = {};
  SimpleKeyPair? _identity;
  String _deviceId = '';
  Timer? _autoLockTimer;
  Timer? _changeSyncDebounce;

  String _query = '';
  NoteSection _section = NoteSection.active;
  String _folderFilter = '';
  String _tagFilter = '';
  String? _selectedNoteId;
  final Set<String> _selection = {};
  bool _selectionMode = false;
  bool _ready = false;

  // ------------------------------------------------------------------ getters

  bool get ready => _ready;
  String get deviceId => _deviceId;
  String get deviceName =>
      _deviceName?.isNotEmpty == true
          ? _deviceName!
          : settings.deviceName.isNotEmpty
              ? settings.deviceName
              : platformDeviceName();
  SyncEngine? get sync => _sync;
  VaultService get vaultService => vault;

  String get query => _query;
  NoteSection get section => _section;
  String get folderFilter => _folderFilter;
  String get tagFilter => _tagFilter;
  String? get selectedNoteId => _selectedNoteId;
  Set<String> get selection => UnmodifiableSetView(_selection);
  bool get selectionMode => _selectionMode;

  List<Folder> get folders =>
      _folders.where((f) => !f.deleted).toList(growable: false);

  /// Every tag in use, sorted.
  List<String> get allTags {
    final tags = <String>{};
    for (final n in _notes.where((n) => !n.deleted)) {
      tags.addAll(n.tags);
    }
    final list = tags.toList()..sort();
    return list;
  }

  List<Note> get notesInTrash =>
      _sorted(_notes.where((n) => n.deleted).toList());

  /// The notes the current filter combination should show.
  List<Note> get visibleNotes {
    Iterable<Note> pool = _notes;
    pool = switch (_section) {
      NoteSection.active => pool.where((n) => !n.deleted && !n.archived),
      NoteSection.archived => pool.where((n) => n.archived && !n.deleted),
      NoteSection.trash => pool.where((n) => n.deleted),
    };
    if (_folderFilter.isNotEmpty) {
      pool = pool.where((n) => n.folderId == _folderFilter);
    }
    if (_tagFilter.isNotEmpty) {
      pool = pool.where((n) => n.tags.contains(_tagFilter));
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      pool = pool.where((n) => _matches(n, q));
    }
    return _sorted(pool.toList());
  }

  bool _matches(Note n, String q) {
    if (n.locked && !vault.isUnlocked) return false;
    final title = displayTitle(n).toLowerCase();
    final body = displayBody(n).toLowerCase();
    return title.contains(q) ||
        body.contains(q) ||
        n.tags.any((t) => t.toLowerCase().contains(q));
  }

  List<Note> _sorted(List<Note> list) {
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return switch (settings.sort) {
        NoteSort.updated => b.updatedAt.compareTo(a.updatedAt),
        NoteSort.created => b.createdAt.compareTo(a.createdAt),
        NoteSort.title =>
          displayTitle(a).toLowerCase().compareTo(displayTitle(b).toLowerCase()),
      };
    });
    return list;
  }

  Note? noteById(String id) {
    for (final n in _notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  Folder? folderById(String id) {
    for (final f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Title for display — plaintext for normal notes, decrypted cache when
  /// the vault is open, a placeholder otherwise.
  String displayTitle(Note n) {
    if (!n.locked) return n.title.isEmpty ? 'Untitled' : n.title;
    final cached = _plaintext[n.id];
    if (cached != null) {
      return cached.title.isEmpty ? 'Untitled' : cached.title;
    }
    return 'Locked note';
  }

  String displayBody(Note n) {
    if (!n.locked) return n.body;
    return _plaintext[n.id]?.body ?? '';
  }

  int noteCountInFolder(String folderId) =>
      _notes.where((n) => !n.deleted && n.folderId == folderId).length;

  // -------------------------------------------------------------------- init

  Future<void> init() async {
    _deviceId = settings.deviceId;
    if (_deviceId.isEmpty) {
      _deviceId = _uuid.v4();
      settings.deviceId = _deviceId;
    }
    await _loadIdentity();
    vault.loadJson(await storage.readJson('vault.json'));
    await _loadFolders();
    await _loadNotes();
    await _loadPeerKeys();
    if (!isWeb) {
      _sync = _syncOverride ??
          platform.createPlatformSyncEngine(
            store: this,
            crypto: crypto,
            deviceId: _deviceId,
            deviceName: deviceName,
            identity: _identity!,
          );
      if (settings.syncEnabled) await _sync!.start();
    } else {
      _sync = _syncOverride;
    }
    if (!settings.seenWelcome && _notes.isEmpty) {
      _seedWelcome();
      settings.seenWelcome = true;
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> _loadIdentity() async {
    final json = await storage.readJson('identity.json');
    if (json != null) {
      _identity = await crypto.x25519FromSeed(crypto.unb64(json['seed']));
      _deviceName = json['name'] as String?;
      return;
    }
    _identity = await crypto.newIdentity();
    await _saveIdentity();
  }

  Future<void> _saveIdentity() async {
    final seed = await crypto.identitySeed(_identity!);
    await storage.writeJson('identity.json', {
      'seed': crypto.b64(seed),
      'name': _deviceName,
    });
  }

  Future<void> _loadFolders() async {
    final json = await storage.readJson('folders.json');
    final list = json?['folders'] as List? ?? [];
    _folders
      ..clear()
      ..addAll(list
          .map((f) => Folder.fromJson((f as Map).cast<String, dynamic>())));
  }

  Future<void> _saveFolders() =>
      storage.writeJson('folders.json',
          {'folders': _folders.map((f) => f.toJson()).toList()});

  Future<void> _loadNotes() async {
    _notes.clear();
    for (final name in await storage.list('notes')) {
      final json = await storage.readJson('notes/$name');
      if (json != null) _notes.add(Note.fromJson(json));
    }
  }

  Future<void> _saveNote(Note n) =>
      storage.writeJson('notes/${n.id}.json', n.toJson());

  Future<void> _loadPeerKeys() async {
    final json = await storage.readJson('peers.json');
    for (final entry in (json?['peers'] as List? ?? []).cast<Map>()) {
      final e = entry.cast<String, dynamic>();
      _peerKeys[e['id'] as String] =
          SecretKey(crypto.unb64(e['key'] as String));
      _peerNames[e['id'] as String] = e['name'] as String? ?? 'device';
    }
  }

  Future<void> _savePeerKeys() async {
    final entries = <Map<String, dynamic>>[];
    for (final id in List.of(_peerKeys.keys)) {
      entries.add({
        'id': id,
        'name': _peerNames[id] ?? 'device',
        'key': crypto.b64(await _peerKeys[id]!.extractBytes()),
      });
    }
    await storage.writeJson('peers.json', {'peers': entries});
  }

  void _seedWelcome() {
    final note = _newNote(
      title: 'Welcome to Moat',
      body: '# Welcome to Moat\n\n'
          'Notes live on your devices — not on a server.\n\n'
          '- **Sync** pairs devices over your local network\n'
          '- **Lock** encrypts a note with your vault passphrase\n'
          '- **Markdown** is fully supported, tap preview to see it\n\n'
          'Open settings to set a vault passphrase.',
    );
    note.tags = ['welcome'];
    _notes.add(note);
    unawaited(_saveNote(note));
  }

  Note _newNote({String title = '', String body = ''}) {
    final now = DateTime.now();
    return Note(
      id: _uuid.v4(),
      title: title,
      body: body,
      createdAt: now,
      updatedAt: now,
      clock: Clock.tick(const {}, _deviceId),
    );
  }

  void _touched(Note n) {
    n.updatedAt = DateTime.now();
    n.clock = Clock.tick(n.clock, _deviceId);
  }

  // ------------------------------------------------------------ note actions

  Note createNote({String folderId = '', List<String> tags = const []}) {
    final note = _newNote()..folderId = folderId;
    note.tags = List.of(tags);
    _notes.add(note);
    _selectedNoteId = note.id;
    unawaited(_saveNote(note));
    _scheduleSyncBroadcast();
    notifyListeners();
    return note;
  }

  /// Persists an edit. [contentChanged] records a revision first.
  Future<void> updateNote(Note note,
      {String? title,
      String? body,
      bool contentChanged = false}) async {
    if (contentChanged) note.pushRevision();
    if (note.locked && vault.isUnlocked && note.lockedPayload != null) {
      final nextTitle = title ?? _plaintext[note.id]?.title ?? '';
      final nextBody = body ?? _plaintext[note.id]?.body ?? '';
      note.lockedPayload =
          await vault.reseal(note.lockedPayload!, nextTitle, nextBody);
      _plaintext[note.id] = (title: nextTitle, body: nextBody);
    } else {
      if (title != null) note.title = title;
      if (body != null) note.body = body;
    }
    _touched(note);
    await _saveNote(note);
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  void selectNote(String? id) {
    _selectedNoteId = id;
    notifyListeners();
  }

  Future<void> togglePin(Note n) async {
    n.pinned = !n.pinned;
    _touched(n);
    await _saveNote(n);
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> setArchived(Note n, bool archived) async {
    n.archived = archived;
    if (archived) n.pinned = false;
    _touched(n);
    await _saveNote(n);
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> moveToTrash(Note n) async {
    n.deleted = true;
    n.pinned = false;
    if (_selectedNoteId == n.id) _selectedNoteId = null;
    _touched(n);
    await _saveNote(n);
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> restoreFromTrash(Note n) async {
    n.deleted = false;
    _touched(n);
    await _saveNote(n);
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> deleteForever(Note n) async {
    _notes.removeWhere((x) => x.id == n.id);
    _plaintext.remove(n.id);
    await storage.delete('notes/${n.id}.json');
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> emptyTrash() async {
    final doomed = _notes.where((n) => n.deleted).toList();
    _notes.removeWhere((n) => n.deleted);
    for (final n in doomed) {
      _plaintext.remove(n.id);
      await storage.delete('notes/${n.id}.json');
    }
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> setFolder(Note n, String folderId) async {
    n.folderId = folderId;
    _touched(n);
    await _saveNote(n);
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> setColor(Note n, int colorIndex) async {
    n.colorIndex = colorIndex;
    _touched(n);
    await _saveNote(n);
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> setTags(Note n, List<String> tags) async {
    n.tags = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    _touched(n);
    await _saveNote(n);
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> restoreRevision(Note n, Revision rev) async {
    await updateNote(n, title: rev.title, body: rev.body, contentChanged: true);
  }

  // ------------------------------------------------------------------ folders

  Folder createFolder(String name, {int colorIndex = -1}) {
    final folder = Folder(
      id: _uuid.v4(),
      name: name,
      createdAt: DateTime.now(),
      clock: Clock.tick(const {}, _deviceId),
      colorIndex: colorIndex,
    );
    _folders.add(folder);
    unawaited(_saveFolders());
    _scheduleSyncBroadcast();
    notifyListeners();
    return folder;
  }

  Future<void> renameFolder(Folder f, String name) async {
    f.name = name;
    f.clock = Clock.tick(f.clock, _deviceId);
    await _saveFolders();
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> deleteFolder(Folder f) async {
    f.deleted = true;
    f.clock = Clock.tick(f.clock, _deviceId);
    for (final n in _notes.where((n) => n.folderId == f.id)) {
      n.folderId = '';
      await _saveNote(n);
    }
    if (_folderFilter == f.id) _folderFilter = '';
    await _saveFolders();
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  // ------------------------------------------------------------------ filters

  void setQuery(String q) {
    _query = q;
    notifyListeners();
  }

  void setSection(NoteSection s) {
    _section = s;
    _tagFilter = '';
    notifyListeners();
  }

  void setFolderFilter(String id) {
    _folderFilter = _folderFilter == id ? '' : id;
    notifyListeners();
  }

  void setTagFilter(String tag) {
    _tagFilter = _tagFilter == tag ? '' : tag;
    notifyListeners();
  }

  void setSort(NoteSort sort) {
    settings.sort = sort;
    notifyListeners();
  }

  void setGridView(bool v) {
    settings.gridView = v;
    notifyListeners();
  }

  void setDensity(ListDensity d) {
    settings.density = d;
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    settings.themeMode = mode;
    notifyListeners();
  }

  void setAccent(int colorValue) {
    settings.accentColor = colorValue;
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    _deviceName = name;
    settings.deviceName = name;
    await _saveIdentity();
    notifyListeners();
  }

  // --------------------------------------------------------------- selection

  void toggleSelection(String id) {
    if (!_selection.add(id)) _selection.remove(id);
    _selectionMode = _selection.isNotEmpty;
    notifyListeners();
  }

  void clearSelection() {
    _selection.clear();
    _selectionMode = false;
    notifyListeners();
  }

  List<Note> get selectedNotes =>
      _notes.where((n) => _selection.contains(n.id)).toList();

  Future<void> batchMoveToTrash() async {
    for (final n in selectedNotes) {
      await moveToTrash(n);
    }
    clearSelection();
  }

  Future<void> batchArchive() async {
    for (final n in selectedNotes) {
      await setArchived(n, true);
    }
    clearSelection();
  }

  Future<void> batchPin() async {
    for (final n in selectedNotes) {
      if (!n.pinned) await togglePin(n);
    }
    clearSelection();
  }

  // ------------------------------------------------------------------- vault

  /// Locks a note: its title+body get encrypted under a fresh note key
  /// wrapped by the vault key.
  Future<bool> lockNote(Note n) async {
    if (!vault.isUnlocked) return false;
    final title = n.locked ? _plaintext[n.id]?.title ?? '' : n.title;
    final body = n.locked ? _plaintext[n.id]?.body ?? '' : n.body;
    n.lockedPayload = await vault.seal(title, body);
    n.locked = true;
    n.title = '';
    n.body = '';
    _plaintext[n.id] = (title: title, body: body);
    _touched(n);
    await _saveNote(n);
    _scheduleSyncBroadcast();
    notifyListeners();
    return true;
  }

  /// Decrypts a locked note into the session cache. Vault must be unlocked.
  Future<bool> openNote(Note n) async {
    if (!n.locked || n.lockedPayload == null || !vault.isUnlocked) {
      return !n.locked;
    }
    try {
      _plaintext[n.id] = await vault.open(n.lockedPayload!);
      notifyListeners();
      return true;
    } on SecretBoxAuthenticationError {
      return false;
    }
  }

  Future<void> unlockNote(Note n) async {
    if (!n.locked || !vault.isUnlocked) return;
    final plain = await vault.open(n.lockedPayload!);
    n
      ..locked = false
      ..title = plain.title
      ..body = plain.body
      ..lockedPayload = null;
    _plaintext.remove(n.id);
    _touched(n);
    await _saveNote(n);
    _scheduleSyncBroadcast();
    notifyListeners();
  }

  Future<void> setVaultPassphrase(String passphrase) async {
    await vault.setPassphrase(passphrase);
    await _saveVault();
    _resetAutoLock();
    notifyListeners();
  }

  Future<bool> unlockVault(String passphrase) async {
    final ok = await vault.unlock(passphrase);
    if (ok) {
      _plaintext.clear();
      _resetAutoLock();
      // Decrypt anything we can so locked rows render immediately.
      for (final n in _notes.where((n) => n.locked)) {
        await openNote(n);
      }
      notifyListeners();
    }
    return ok;
  }

  /// Biometric unlock path — still needs the passphrase cached nowhere, so
  /// biometric just guards showing the passphrase prompt.
  Future<bool> biometricUnlock() => biometric.authenticate('Unlock Moat');

  void lockVault() {
    vault.lock();
    _plaintext.clear();
    _autoLockTimer?.cancel();
    notifyListeners();
  }

  Future<void> changeVaultPassphrase(String newPassphrase) async {
    final locked = _notes.where((n) => n.locked).toList();
    await vault.changePassphrase(newPassphrase, locked);
    for (final n in locked) {
      await _saveNote(n);
    }
    await _saveVault();
    notifyListeners();
  }

  /// Removes the vault, decrypting every locked note back to plaintext.
  Future<void> removeVault() async {
    if (!vault.isUnlocked) return;
    for (final n in _notes.where((n) => n.locked).toList()) {
      await unlockNote(n);
    }
    vault.record = null;
    vault.lock();
    await storage.delete('vault.json');
    notifyListeners();
  }

  Future<void> _saveVault() async {
    final json = vault.toJson();
    if (json != null) {
      await storage.writeJson('vault.json', json);
    }
  }

  /// Resets the inactivity countdown that re-locks an open vault.
  void touch() {
    if (vault.isUnlocked) _resetAutoLock();
  }

  void _resetAutoLock() {
    _autoLockTimer?.cancel();
    final seconds = settings.autoLockSeconds;
    if (seconds <= 0) return;
    _autoLockTimer = Timer(Duration(seconds: seconds), lockVault);
  }

  /// The wrapped-key exchange only makes sense when both devices share a
  /// vault, so a passphrase must exist before pairing can carry locked notes.
  bool get canLockNotes => vault.hasVault;

  // --------------------------------------------------------------------- sync

  Future<void> setSyncEnabled(bool enabled) async {
    settings.syncEnabled = enabled;
    if (_sync == null) return;
    if (enabled) {
      await _sync!.start();
    } else {
      await _sync!.stop();
    }
    notifyListeners();
  }

  List<SyncPeer> get peers => _sync?.peers ?? const [];
  String peerName(String deviceId) => _peerNames[deviceId] ?? 'device';

  bool isPeerTrusted(String deviceId) => _peerKeys.containsKey(deviceId);

  Future<void> pairWith(
          SyncPeer peer, Future<String> Function() askCode) =>
      _sync!.pairWith(peer, askCode);

  Future<void> syncNow() => _sync?.syncNow() ?? Future.value();

  void unpairPeer(String deviceId) {
    _peerKeys.remove(deviceId);
    _peerNames.remove(deviceId);
    unawaited(_savePeerKeys());
    _sync?.unpair(deviceId);
    notifyListeners();
  }

  void _scheduleSyncBroadcast() {
    // Only bother waking the engine when it's running and at least one
    // paired peer is around to receive the update.
    if (_sync?.running != true || !peers.any((p) => p.paired)) return;
    _changeSyncDebounce?.cancel();
    _changeSyncDebounce =
        Timer(const Duration(seconds: 2), () => unawaited(syncNow()));
  }

  // ---------------------------------------------------- SyncStore (engine in)

  @override
  List<Map<String, dynamic>> noteManifest() => [
        for (final n in _notes)
          {
            'id': n.id,
            'clock': Map<String, int>.from(n.clock),
            'u': n.updatedAt.millisecondsSinceEpoch,
            'del': n.deleted,
          }
      ];

  @override
  List<Map<String, dynamic>> folderManifest() => [
        for (final f in _folders)
          {'id': f.id, 'clock': Map<String, int>.from(f.clock)}
      ];

  @override
  Map<String, dynamic>? notePayload(String id) => noteById(id)?.toJson();

  @override
  Map<String, dynamic>? folderPayload(String id) {
    for (final f in _folders) {
      if (f.id == id) return f.toJson();
    }
    return null;
  }

  @override
  String applyRemoteNote(Map<String, dynamic> json) {
    final remote = Note.fromJson(json);
    final local = noteById(remote.id);
    if (local == null) {
      _notes.add(remote);
      return 'applied';
    }
    switch (Clock.compare(local.clock, remote.clock)) {
      case ClockOrder.equal:
      case ClockOrder.dominant:
        return 'kept-local';
      case ClockOrder.dominated:
        final index = _notes.indexOf(local);
        _notes[index] = remote;
        _plaintext.remove(remote.id);
        return 'applied';
      case ClockOrder.concurrent:
        // Keep ours; file theirs as a separate conflict copy.
        _notes.add(remote.asConflictCopy(_uuid.v4()));
        return 'conflict';
    }
  }

  @override
  String applyRemoteFolder(Map<String, dynamic> json) {
    final remote = Folder.fromJson(json);
    final local = folderById(remote.id);
    if (local == null) {
      _folders.add(remote);
      return 'applied';
    }
    switch (Clock.compare(local.clock, remote.clock)) {
      case ClockOrder.equal:
      case ClockOrder.dominant:
        return 'kept-local';
      case ClockOrder.dominated:
        _folders[_folders.indexOf(local)] = remote;
        return 'applied';
      case ClockOrder.concurrent:
        // Folders carry little state; on divergence take the peer's copy.
        _folders[_folders.indexOf(local)] = remote;
        return 'conflict';
    }
  }

  @override
  VaultRecord? get vaultRecord => vault.record;

  @override
  bool adoptVaultRecord(Map<String, dynamic> json) =>
      vault.adoptRecord(VaultRecord.fromJson(json));

  @override
  SecretKey? ltKeyFor(String deviceId) => _peerKeys[deviceId];

  @override
  void storeLtKey(String deviceId, String name, SecretKey key) {
    _peerKeys[deviceId] = key;
    _peerNames[deviceId] = name;
    unawaited(_savePeerKeys());
    notifyListeners();
  }

  @override
  void removeLtKey(String deviceId) {
    _peerKeys.remove(deviceId);
    _peerNames.remove(deviceId);
    unawaited(_savePeerKeys());
    notifyListeners();
  }

  @override
  bool hasLtKey(String deviceId) => _peerKeys.containsKey(deviceId);

  @override
  void onSyncApplied() {
    unawaited(_persistAll());
    notifyListeners();
  }

  Future<void> _persistAll() async {
    await _saveFolders();
    for (final n in _notes) {
      await _saveNote(n);
    }
    await _saveVault();
  }

  // ------------------------------------------------------------------ export

  Future<String> exportBackup() async {
    final dir = await storage.exportDirectory();
    final file = await exportToFile(dir, _notes, _folders);
    return file.path;
  }

  Future<({int notes, int folders})> importBackup(String path) async {
    final parsed = await importFile(path);
    var noteCount = 0;
    var folderCount = 0;
    for (final f in parsed.folders) {
      if (folderById(f.id) == null &&
          _folders.every((x) => x.id != f.id)) {
        _folders.add(f);
        folderCount++;
      }
    }
    for (final n in parsed.notes) {
      if (noteById(n.id) == null) {
        _notes.add(n);
        await _saveNote(n);
        noteCount++;
      }
    }
    await _saveFolders();
    notifyListeners();
    return (notes: noteCount, folders: folderCount);
  }

  Future<String> exportNoteMarkdown(Note n,
      {String? title, String? body}) async {
    final dir = await storage.exportDirectory();
    final file = await exportNoteMarkdownFile(dir, n,
        title: title ?? displayTitle(n), body: body ?? displayBody(n));
    return file.path;
  }

  // ------------------------------------------------------------------- misc

  @override
  void dispose() {
    _autoLockTimer?.cancel();
    _changeSyncDebounce?.cancel();
    _sync?.dispose();
    super.dispose();
  }
}
