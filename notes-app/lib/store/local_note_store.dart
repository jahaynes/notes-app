import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../note.dart';
import '../topic.dart';
import 'note_store.dart';

/// Keeps notes and topics in memory and persists them to SharedPreferences as
/// JSON.
class LocalNoteStore extends NoteStore {
  LocalNoteStore(this._prefs)
    : _notes = ValueNotifier(_load(_prefs)),
      _topics = ValueNotifier(_loadTopics(_prefs));

  static const _key = 'notes_v1';
  static const _topicsKey = 'topics_v1';

  final SharedPreferences _prefs;
  final ValueNotifier<List<Note>> _notes;
  final ValueNotifier<List<Topic>> _topics;
  final _lastDeleted = ValueNotifier<Note?>(null);

  @override
  ValueListenable<List<Note>> get notes => _notes;

  @override
  ValueListenable<List<Topic>> get topics => _topics;

  @override
  ValueListenable<Note?> get lastDeleted => _lastDeleted;

  @override
  Future<void> dispatch(NoteAction action) async {
    switch (action) {
      case SaveNote(:final note):
        if (note.id == _lastDeleted.value?.id) _lastDeleted.value = null;
        final topicExists = _topics.value.any((t) => t.id == note.topicId);
        await _setNotes([
          for (final n in _notes.value)
            if (n.id != note.id) n,
          if (!note.isEmpty)
            topicExists ? note : note.copyWith(topicId: Topic.uncategorisedId),
        ]);
      case DeleteNote(:final id):
        final deleted = byId(id);
        if (deleted == null) return;
        _lastDeleted.value = deleted;
        await _setNotes([
          for (final n in _notes.value)
            if (n.id != id) n,
        ]);
      case AddTopic(:final topic):
        await _setTopics([..._topics.value, topic]);
      case DeleteTopic(:final id):
        if (id == Topic.uncategorisedId) return;
        await _setTopics([
          for (final t in _topics.value)
            if (t.id != id) t,
        ]);
        if (_notes.value.any((n) => n.topicId == id)) {
          await _setNotes([
            for (final n in _notes.value)
              n.topicId == id ? n.copyWith(topicId: Topic.uncategorisedId) : n,
          ]);
        }
    }
  }

  Future<void> _setNotes(List<Note> notes) async {
    final next = _sorted(notes);
    _notes.value = next;
    await _prefs.setString(
      _key,
      jsonEncode(next.map((n) => n.toJson()).toList()),
    );
  }

  Future<void> _setTopics(List<Topic> topics) async {
    _topics.value = List.unmodifiable(topics);
    // The default topic is implicit, so it isn't stored.
    await _prefs.setString(
      _topicsKey,
      jsonEncode([
        for (final t in topics)
          if (!t.isDefault) t.toJson(),
      ]),
    );
  }

  static List<Note> _load(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    return _sorted(
      list.map((e) => Note.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  static List<Topic> _loadTopics(SharedPreferences prefs) {
    final raw = prefs.getString(_topicsKey);
    final list = raw == null ? const [] : jsonDecode(raw) as List<dynamic>;
    return List.unmodifiable([
      Topic.uncategorised,
      for (final e in list) Topic.fromJson(e as Map<String, dynamic>),
    ]);
  }

  static List<Note> _sorted(List<Note> notes) => List.unmodifiable(
    notes..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );
}
