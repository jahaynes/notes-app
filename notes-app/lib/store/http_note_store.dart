import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../note.dart';
import '../topic.dart';
import '../user.dart';
import 'note_store.dart';

/// A request to the backend that came back with a status we don't handle.
class NotesApiException implements Exception {
  NotesApiException(this.request, this.statusCode, this.body);

  final String request;
  final int statusCode;
  final String body;

  @override
  String toString() => 'NotesApiException: $request -> $statusCode $body';
}

/// Keeps notes in the Notes API backend, with the latest state held in
/// memory. Changes show up locally straight away. A changed or deleted note
/// is sent to the backend once it's gone [_writeDelay] without changing
/// again, and requests go one at a time, in the order they were sent.
///
/// This device's id lives in SharedPreferences. The user is whoever logged
/// in with the [Login] the store was opened with: their id goes in request
/// bodies, and every request carries their token.
///
/// Deleting a topic is sent straight away rather than held back, and the
/// backend moves the topic's notes itself.
class HttpNoteStore extends NoteStore {
  HttpNoteStore._(
    this._client,
    this._baseUri,
    this.user,
    this._deviceId,
    List<Topic> topics,
    List<Note> notes,
    this._clocks,
    this._topicClocks,
  ) : _topics = ValueNotifier(topics),
      _notes = ValueNotifier(notes),
      _synced = {for (final n in notes) n.id: n};

  /// Loads the topics and notes of the user who logged in with [login]
  /// from the backend at [baseUri]. Their default topic shares their id, so
  /// that any device can find it. Requests go through [inner], and
  /// [onRejected] is called whenever the backend turns down the token.
  static Future<HttpNoteStore> open(
    http.Client inner,
    Uri baseUri,
    SharedPreferences prefs,
    Login login, {
    required void Function() onRejected,
  }) async {
    final client = _BearerClient(inner, login.token, onRejected);
    final user = User(
      id: login.userId,
      defaultTopic: Topic(id: login.userId, name: 'Uncategorised'),
    );
    var deviceId = prefs.getString(_deviceKey);
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await prefs.setString(_deviceKey, deviceId);
    }

    final topicViews = await _getTopics(client, baseUri, user.id);
    final serverTopics = [for (final json in topicViews) _topicFromView(json)];
    final topicClocks = {
      for (final json in topicViews)
        json['topicId'] as String: _clockFrom(json),
    };
    var defaultTopic = serverTopics
        .where((t) => t.id == user.defaultTopic.id)
        .firstOrNull;
    if (defaultTopic == null) {
      final stored = await _putTopic(
        client,
        baseUri,
        user.id,
        deviceId,
        user.defaultTopic,
      );
      defaultTopic = stored.topic;
      topicClocks[defaultTopic.id] = stored.clock;
    }
    final topics = List<Topic>.unmodifiable([
      defaultTopic,
      for (final t in serverTopics)
        if (t.id != user.defaultTopic.id) t,
    ]);

    final clocks = <String, Map<String, int>>{};
    final notes = <Note>[];
    for (final topicId in topics.map((t) => t.id)) {
      for (final json in await _getNotes(client, baseUri, topicId)) {
        notes.add(_fromView(json));
        clocks[json['noteId'] as String] = _clockFrom(json);
      }
    }
    return HttpNoteStore._(
      client,
      baseUri,
      user,
      deviceId,
      topics,
      _sorted(notes),
      clocks,
      topicClocks,
    );
  }

  static const _deviceKey = 'device_v1';

  /// How long a note must go unchanged before it's written, so that typing
  /// sends a request per pause rather than per keystroke.
  static const _writeDelay = Duration(milliseconds: 500);

  final http.Client _client;
  final Uri _baseUri;
  final String _deviceId;

  @override
  final User user;

  /// The vector clock of each note, and of each topic, as last written or
  /// read.
  final Map<String, Map<String, int>> _clocks;
  final Map<String, Map<String, int>> _topicClocks;

  /// Each note as the backend last confirmed it, by id. A note that differs
  /// from its entry here has changes the backend hasn't seen yet.
  final Map<String, Note> _synced;

  /// Writes waiting out [_writeDelay] before they're sent, by note id.
  final _unsent = <String, _Unsent>{};

  /// Ids of the topics deleted here that the backend hasn't answered for.
  final _deletingTopics = <String>{};

  final ValueNotifier<List<Note>> _notes;
  final ValueNotifier<List<Topic>> _topics;
  final _lastDeleted = ValueNotifier<List<Note>>(const []);

  /// Completes when every request sent so far has finished.
  Future<void> _pending = Future.value();

  @override
  ValueListenable<List<Note>> get notes => _notes;

  @override
  ValueListenable<List<Topic>> get topics => _topics;

  @override
  ValueListenable<List<Note>> get lastDeleted => _lastDeleted;

  /// This device's key in a note's vector clock.
  String get _clockKey => '${user.id}:$_deviceId';

  @override
  Future<void> dispatch(NoteAction action) async {
    switch (action) {
      case SaveNote(:final note):
        await _saveNotes([note]);
      case DeleteNotes(:final ids):
        final idSet = ids.toSet();
        final deleted = [
          for (final n in _notes.value)
            if (idSet.contains(n.id)) n,
        ];
        if (deleted.isEmpty) return;
        _lastDeleted.value = List.unmodifiable(deleted);
        _notes.value = _sorted([
          for (final n in _notes.value)
            if (!idSet.contains(n.id)) n,
        ]);
        await Future.wait([for (final n in deleted) _write(n.id, _Delete())]);
      case MoveNotes(:final ids, :final topicId):
        final idSet = ids.toSet();
        await _saveNotes([
          for (final n in _notes.value)
            if (idSet.contains(n.id) && n.topicId != topicId)
              n.copyWith(topicId: topicId),
        ]);
      case UndoDelete():
        await _saveNotes(_lastDeleted.value);
      case AddTopic(:final topic):
        _topics.value = List.unmodifiable([..._topics.value, topic]);
        await _enqueue(() async {
          final stored = await _putTopic(
            _client,
            _baseUri,
            user.id,
            _deviceId,
            topic,
          );
          _topicClocks[topic.id] = stored.clock;
          if (stored.topic == topic) return;
          _topics.value = List.unmodifiable([
            for (final t in _topics.value)
              t.id == topic.id ? stored.topic : t,
          ]);
        });
      case DeleteTopics(:final ids):
        final idSet = ids.toSet()..remove(defaultTopic.id);
        final deleted = [
          for (final t in _topics.value)
            if (idSet.contains(t.id)) t,
        ];
        if (deleted.isEmpty) return;
        _deletingTopics.addAll(idSet);
        _topics.value = List.unmodifiable([
          for (final t in _topics.value)
            if (!idSet.contains(t.id)) t,
        ]);
        // The backend moves the notes itself, so only writes already waiting
        // need to follow them.
        final moved = <String, Set<String>>{};
        _notes.value = _sorted([
          for (final n in _notes.value)
            if (idSet.contains(n.topicId))
              _moveNote(n, defaultTopic.id, moved.putIfAbsent(n.topicId, () => {}))
            else
              n,
        ]);
        final shared = await Future.wait([
          for (final t in deleted)
            _enqueue(() => _deleteTopic(t, moved[t.id] ?? const {})),
        ]);
        final refused = [
          for (final (i, t) in deleted.indexed)
            if (shared[i]) t,
        ];
        if (refused.isNotEmpty) throw SharedTopicsNotDeleted(refused);
    }
  }

  /// [note] moved into the topic [topicId], with any write waiting for it
  /// moved along too. Adds its id to [moved].
  Note _moveNote(Note note, String topicId, Set<String> moved) {
    final next = note.copyWith(topicId: topicId);
    moved.add(note.id);
    if (_unsent[note.id]?.write is _Put) _write(note.id, _Put(next));
    return next;
  }

  /// Deletes [topic] from the backend, which moves its notes to the default
  /// topic as [dispatch] already has here for the notes [moved]. If the
  /// backend keeps the topic, it comes back here with those notes, and this
  /// returns whether that was because it's shared and still has notes.
  Future<bool> _deleteTopic(Topic topic, Set<String> moved) async {
    final path = 'topic/${topic.id}';
    final http.Response response;
    try {
      response = await _client.delete(
        _baseUri.resolve(path),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': user.id,
          'deviceId': _deviceId,
          'clock': _topicClocks[topic.id] ?? const <String, int>{},
          'moveNotesTo': defaultTopic.id,
        }),
      );
    } finally {
      _deletingTopics.remove(topic.id);
    }
    switch (response.statusCode) {
      case 204:
        _topicClocks.remove(topic.id);
        // Follow the backend, which moved every note it had in the topic and
        // ticked this device's entry in each one's clock.
        for (final MapEntry(key: id, value: note) in _synced.entries.toList()) {
          if (note.topicId != topic.id) continue;
          _synced[id] = note.copyWith(topicId: defaultTopic.id);
          _clocks[id] = _ticked(_clocks[id] ?? const {});
        }
        return false;
      case 409:
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        _topicClocks[topic.id] = _clockFrom(json);
        _restoreTopic(_topicFromView(json), moved);
        return false;
      case 422 when jsonDecode(response.body) == 'SharedWithNotes':
        _restoreTopic(topic, moved);
        return true;
      default:
        throw NotesApiException(
          'DELETE $path',
          response.statusCode,
          response.body,
        );
    }
  }

  /// Puts back [topic] after the backend kept it, along with the notes
  /// [moved] out of it that are still in the default topic.
  void _restoreTopic(Topic topic, Set<String> moved) {
    _topics.value = List.unmodifiable([..._topics.value, topic]);
    _notes.value = _sorted([
      for (final n in _notes.value)
        if (moved.contains(n.id) && n.topicId == defaultTopic.id)
          _moveNote(n, topic.id, {})
        else
          n,
    ]);
  }

  /// [clock] with this device's entry advanced, as a write from it would.
  Map<String, int> _ticked(Map<String, int> clock) => {
    ...clock,
    _clockKey: (clock[_clockKey] ?? 0) + 1,
  };

  @override
  Future<void> flush() {
    final writes = [for (final u in _unsent.values) u.done.future];
    _unsent.keys.toList().forEach(_send);
    return Future.wait(writes);
  }

  @override
  Future<void> refreshNote(String id) => _enqueue(() async {
    final path = 'note/$id';
    final response = await _client.get(_baseUri.resolve(path));
    switch (response.statusCode) {
      case 200:
        _merge(
          (n) => n.id == id,
          [jsonDecode(response.body) as Map<String, dynamic>],
        );
      // Never written, so there's only the copy here.
      case 404:
        return;
      default:
        throw NotesApiException('GET $path', response.statusCode, response.body);
    }
  });

  @override
  Future<void> refreshTopic(String? topicId) => _enqueue(() async {
    if (topicId != null) {
      _merge(
        (n) => n.topicId == topicId,
        await _getNotes(_client, _baseUri, topicId),
      );
      return;
    }
    final fetched = <String, Topic>{};
    for (final json in await _getTopics(_client, _baseUri, user.id)) {
      final topic = _topicFromView(json);
      if (_deletingTopics.contains(topic.id)) continue;
      fetched[topic.id] = topic;
      _topicClocks[topic.id] = _clockFrom(json);
    }
    final known = {for (final t in _topics.value) t.id};
    _topics.value = List.unmodifiable([
      for (final t in _topics.value) fetched[t.id] ?? t,
      for (final t in fetched.values)
        if (!known.contains(t.id)) t,
    ]);
    _merge((_) => true, [
      for (final t in _topics.value)
        ...await _getNotes(_client, _baseUri, t.id),
    ]);
  });

  /// Replaces the notes picked out by [inScope] with [views], the backend's
  /// copies of them. Notes with changes the backend hasn't seen yet are left
  /// alone, as their writes will settle them, and that includes notes
  /// waiting to be deleted. An unchanged note in scope that isn't in [views]
  /// has been moved out of scope or deleted elsewhere, so it's dropped.
  ///
  /// Only safe to call from a request run by [_enqueue], so that no write
  /// sent earlier is still in flight.
  void _merge(
    bool Function(Note note) inScope,
    Iterable<Map<String, dynamic>> views,
  ) {
    final fetched = {
      for (final json in views)
        if (!_deleting(json['noteId'] as String))
          json['noteId'] as String: json,
    };
    final next = <Note>[];
    for (final note in _notes.value) {
      if (_synced[note.id] != note) {
        next.add(note);
        fetched.remove(note.id);
      } else if (!inScope(note) && !fetched.containsKey(note.id)) {
        next.add(note);
      }
    }
    for (final json in fetched.values) {
      final note = _fromView(json);
      next.add(note);
      _synced[note.id] = note;
      _clocks[note.id] = _clockFrom(json);
    }
    _notes.value = _sorted(next);
  }

  /// Inserts or replaces [notes] as described by [SaveNote], then writes the
  /// non-empty ones to the backend and deletes the empty ones from it.
  Future<void> _saveNotes(List<Note> notes) async {
    if (notes.isEmpty) return;
    final ids = {for (final n in notes) n.id};
    if (_lastDeleted.value.any((n) => ids.contains(n.id))) {
      _lastDeleted.value = List.unmodifiable(
        _lastDeleted.value.where((n) => !ids.contains(n.id)),
      );
    }
    final topicIds = {for (final t in _topics.value) t.id};
    final saved = [
      for (final n in notes)
        if (!n.isEmpty)
          topicIds.contains(n.topicId)
              ? n
              : n.copyWith(topicId: defaultTopic.id),
    ];
    _notes.value = _sorted([
      for (final n in _notes.value)
        if (!ids.contains(n.id)) n,
      ...saved,
    ]);
    await Future.wait([
      for (final n in saved) _write(n.id, _Put(n)),
      for (final n in notes)
        if (n.isEmpty) _write(n.id, _Delete()),
    ]);
  }

  /// Sends [write] for the note [id] once it's gone [_writeDelay] without
  /// another, replacing any earlier one still waiting. Completes when it has
  /// been sent.
  Future<void> _write(String id, _Write write) {
    final timer = Timer(_writeDelay, () => _send(id));
    final unsent = _unsent[id];
    if (unsent == null) {
      return (_unsent[id] = _Unsent(write, timer)).done.future;
    }
    unsent
      ..timer.cancel()
      ..timer = timer
      ..write = write;
    return unsent.done.future;
  }

  /// Sends the write waiting for the note [id] without waiting any longer.
  void _send(String id) {
    final unsent = _unsent.remove(id);
    if (unsent == null) return;
    unsent.timer.cancel();
    unsent.done.complete(
      _enqueue(
        () => switch (unsent.write) {
          _Put(:final note) => _putNote(note),
          _Delete() => _deleteNote(id),
        },
      ),
    );
  }

  /// Whether the note [id] is waiting to be deleted.
  bool _deleting(String id) => _unsent[id]?.write is _Delete;

  /// Writes [note] with this device's clock entry bumped. On a conflict the
  /// backend keeps its copy and returns it, and that copy replaces ours.
  Future<void> _putNote(Note note) async {
    final clock = _ticked(_clocks[note.id] ?? const {});
    final path = 'note/${note.id}';
    final response = await _client.put(
      _baseUri.resolve(path),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'userId': user.id,
        'deviceId': _deviceId,
        'clock': clock,
        'title': note.title,
        'content': note.body,
        'colorIndex': note.colorIndex,
        'showFull': note.showFull,
        'topicId': note.topicId,
      }),
    );
    switch (response.statusCode) {
      case 204:
        _clocks[note.id] = clock;
        _synced[note.id] = note;
      case 409:
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        _clocks[note.id] = _clockFrom(json);
        final stored = _fromView(json);
        _synced[stored.id] = stored;
        if (_deleting(stored.id)) return;
        _replaceNote(stored);
      default:
        throw NotesApiException(
          'PUT $path',
          response.statusCode,
          response.body,
        );
    }
  }

  /// Deletes the note [id] from the backend. If it's been changed elsewhere
  /// since this store last saw it, the backend keeps it and returns it, and
  /// it comes back here with those changes.
  Future<void> _deleteNote(String id) async {
    final clock = _clocks[id];
    // Never written or read, so the backend hasn't got it.
    if (clock == null) return;
    final path = 'note/$id';
    final response = await _client.delete(
      _baseUri.resolve(path),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'clock': clock}),
    );
    switch (response.statusCode) {
      case 204:
        _clocks.remove(id);
        _synced.remove(id);
      case 409:
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        _clocks[id] = _clockFrom(json);
        final stored = _fromView(json);
        _synced[id] = stored;
        // Undoing the delete would put back the version it overrode.
        if (_lastDeleted.value.any((n) => n.id == id)) {
          _lastDeleted.value = List.unmodifiable(
            _lastDeleted.value.where((n) => n.id != id),
          );
        }
        _replaceNote(stored);
      default:
        throw NotesApiException(
          'DELETE $path',
          response.statusCode,
          response.body,
        );
    }
  }

  /// Puts [note] in place of the note with its id, adding it if there's none.
  void _replaceNote(Note note) => _notes.value = _sorted([
    for (final n in _notes.value)
      if (n.id != note.id) n,
    note,
  ]);

  /// Runs [request] once every earlier one has finished, so writes reach the
  /// backend in order and each sees the clock the one before it left.
  Future<T> _enqueue<T>(Future<T> Function() request) {
    final result = _pending.then((_) => request());
    // A failed request mustn't stop the ones after it.
    _pending = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// GETs [path], which must answer 200 with JSON.
  static Future<dynamic> _get(
    http.Client client,
    Uri baseUri,
    String path,
  ) async {
    final response = await client.get(baseUri.resolve(path));
    if (response.statusCode != 200) {
      throw NotesApiException('GET $path', response.statusCode, response.body);
    }
    return jsonDecode(response.body);
  }

  /// The TopicViews of the user's topics, oldest first as a stand-in for the
  /// order they were added.
  static Future<List<Map<String, dynamic>>> _getTopics(
    http.Client client,
    Uri baseUri,
    String userId,
  ) async => [
    for (final view in await _get(client, baseUri, 'user/$userId/topics')
        as List)
      view as Map<String, dynamic>,
  ]..sort((a, b) => _updatedAt(a).compareTo(_updatedAt(b)));

  /// The NoteViews of the notes in the topic [topicId].
  static Future<List<Map<String, dynamic>>> _getNotes(
    http.Client client,
    Uri baseUri,
    String topicId,
  ) async => [
    for (final view in await _get(client, baseUri, 'topic/$topicId/notes')
        as List)
      view as Map<String, dynamic>,
  ];

  /// Creates [topic] and adds it to the user's topics. Returns the topic as
  /// the backend now has it, which is its own copy if a topic with that id
  /// already existed there, and its clock.
  static Future<({Topic topic, Map<String, int> clock})> _putTopic(
    http.Client client,
    Uri baseUri,
    String userId,
    String deviceId,
    Topic topic,
  ) async {
    final path = 'topic/${topic.id}';
    final response = await client.put(
      baseUri.resolve(path),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'userId': userId,
        'deviceId': deviceId,
        'name': topic.name,
      }),
    );
    switch (response.statusCode) {
      // Written without a clock, which the backend starts at zero for this
      // device.
      case 204:
        return (topic: topic, clock: {'$userId:$deviceId': 0});
      case 409:
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return (topic: _topicFromView(json), clock: _clockFrom(json));
      default:
        throw NotesApiException(
          'PUT $path',
          response.statusCode,
          response.body,
        );
    }
  }

  /// Decodes a TopicView.
  static Topic _topicFromView(Map<String, dynamic> json) =>
      Topic(id: json['topicId'] as String, name: json['name'] as String);

  /// Decodes a NoteView.
  static Note _fromView(Map<String, dynamic> json) => Note(
    id: json['noteId'] as String,
    title: json['title'] as String,
    body: json['content'] as String,
    colorIndex: json['colorIndex'] as int,
    showFull: json['showFull'] as bool,
    topicId: json['topicId'] as String,
    updatedAt: _updatedAt(json).toLocal(),
  );

  static DateTime _updatedAt(Map<String, dynamic> json) =>
      DateTime.parse(json['updatedAt'] as String);

  static Map<String, int> _clockFrom(Map<String, dynamic> json) =>
      (json['clock'] as Map<String, dynamic>).cast<String, int>();

  static List<Note> _sorted(List<Note> notes) => List.unmodifiable(
    notes..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );
}

/// Sends every request with [_token] as its bearer token, calling
/// [_onRejected] each time the backend answers 401.
class _BearerClient extends http.BaseClient {
  _BearerClient(this._inner, this._token, this._onRejected);

  final http.Client _inner;
  final String _token;
  final void Function() _onRejected;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['Authorization'] = 'Bearer $_token';
    final response = await _inner.send(request);
    if (response.statusCode == 401) _onRejected();
    return response;
  }
}

/// What [HttpNoteStore] sends the backend for a note.
sealed class _Write {}

final class _Put extends _Write {
  _Put(this.note);

  final Note note;
}

final class _Delete extends _Write {}

/// A write held back by [HttpNoteStore._write] until the note stops changing.
class _Unsent {
  _Unsent(this.write, this.timer);

  _Write write;
  Timer timer;

  /// Completes once [write], or whichever write replaces it, is sent.
  final done = Completer<void>();
}
