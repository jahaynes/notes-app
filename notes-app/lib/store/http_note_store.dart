import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../note.dart';
import '../topic.dart';
import '../user.dart';
import 'local_note_store.dart';
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
/// memory. Changes show up locally straight away and are sent to the backend
/// one at a time, in the order they were dispatched.
///
/// This device's id lives in SharedPreferences, as does the user unless
/// one is passed to [open].
///
/// The backend can't delete notes or remove topics yet, so [DeleteNotes],
/// saving an empty note and [DeleteTopics] only change what this store
/// holds in memory, and the deleted things come back the next time it's
/// opened. Notes moved out of a deleted topic do stay moved.
class HttpNoteStore extends NoteStore {
  HttpNoteStore._(
    this._client,
    this._baseUri,
    this.user,
    this._deviceId,
    List<Topic> topics,
    List<Note> notes,
    this._clocks,
  ) : _topics = ValueNotifier(topics),
      _notes = ValueNotifier(notes);

  /// Loads the user's topics and notes from the backend at [baseUri].
  ///
  /// The user is [userId] if given, whose default topic shares their id so
  /// that any device can find it. Otherwise it's the user saved in [prefs].
  static Future<HttpNoteStore> open(
    http.Client client,
    Uri baseUri,
    SharedPreferences prefs, {
    String? userId,
  }) async {
    final user = userId == null
        ? await LocalNoteStore.loadUser(prefs)
        : User(
            id: userId,
            defaultTopic: Topic(id: userId, name: 'Uncategorised'),
          );
    var deviceId = prefs.getString(_deviceKey);
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await prefs.setString(_deviceKey, deviceId);
    }

    Future<dynamic> get(String path) async {
      final response = await client.get(baseUri.resolve(path));
      if (response.statusCode != 200) {
        throw NotesApiException(
          'GET $path',
          response.statusCode,
          response.body,
        );
      }
      return jsonDecode(response.body);
    }

    // Oldest first, as a stand-in for the order they were added.
    final views = [
      for (final view in await get('user/${user.id}/topics') as List)
        view as Map<String, dynamic>,
    ]..sort((a, b) => _updatedAt(a).compareTo(_updatedAt(b)));
    final serverTopics = [for (final json in views) _topicFromView(json)];
    final serverDefault = serverTopics
        .where((t) => t.id == user.defaultTopic.id)
        .firstOrNull;
    if (serverDefault == null) {
      await _putTopic(client, baseUri, user.id, deviceId, user.defaultTopic);
    }
    final topics = List<Topic>.unmodifiable([
      serverDefault ?? user.defaultTopic,
      for (final t in serverTopics)
        if (t.id != user.defaultTopic.id) t,
    ]);

    final clocks = <String, Map<String, int>>{};
    final notes = <Note>[];
    for (final topicId in topics.map((t) => t.id)) {
      for (final view in await get('topic/$topicId/notes') as List) {
        final json = view as Map<String, dynamic>;
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
    );
  }

  static const _deviceKey = 'device_v1';

  final http.Client _client;
  final Uri _baseUri;
  final String _deviceId;

  @override
  final User user;

  /// The vector clock of each note as last written or read.
  final Map<String, Map<String, int>> _clocks;

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
          if (stored == null) return;
          _topics.value = List.unmodifiable([
            for (final t in _topics.value) t.id == stored.id ? stored : t,
          ]);
        });
      case DeleteTopics(:final ids):
        final idSet = ids.toSet()..remove(defaultTopic.id);
        if (idSet.isEmpty) return;
        _topics.value = List.unmodifiable([
          for (final t in _topics.value)
            if (!idSet.contains(t.id)) t,
        ]);
        await _saveNotes([
          for (final n in _notes.value)
            if (idSet.contains(n.topicId)) n.copyWith(topicId: defaultTopic.id),
        ]);
    }
  }

  /// Inserts or replaces [notes] as described by [SaveNote], then writes the
  /// non-empty ones to the backend.
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
    await Future.wait([for (final n in saved) _enqueue(() => _putNote(n))]);
  }

  /// Writes [note] with this device's clock entry bumped. On a conflict the
  /// backend keeps its copy and returns it, and that copy replaces ours.
  Future<void> _putNote(Note note) async {
    final clock = {..._clocks[note.id] ?? const <String, int>{}};
    clock[_clockKey] = (clock[_clockKey] ?? 0) + 1;
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
      case 409:
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        _clocks[note.id] = _clockFrom(json);
        final stored = _fromView(json);
        _notes.value = _sorted([
          for (final n in _notes.value)
            if (n.id != stored.id) n,
          stored,
        ]);
      default:
        throw NotesApiException(
          'PUT $path',
          response.statusCode,
          response.body,
        );
    }
  }

  /// Runs [request] once every earlier one has finished, so writes reach the
  /// backend in order and each sees the clock the one before it left.
  Future<void> _enqueue(Future<void> Function() request) {
    final result = _pending.then((_) => request());
    // A failed request mustn't stop the ones after it.
    _pending = result.catchError((_) {});
    return result;
  }

  /// Creates [topic] and adds it to the user's topics. Returns null if it
  /// was written, or the backend's copy if a topic with that id already
  /// exists there.
  static Future<Topic?> _putTopic(
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
      case 204:
        return null;
      case 409:
        return _topicFromView(
          jsonDecode(response.body) as Map<String, dynamic>,
        );
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
