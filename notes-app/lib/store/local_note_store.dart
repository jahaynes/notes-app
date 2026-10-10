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
  final _lastDeleted = ValueNotifier<List<Note>>(const []);

  @override
  ValueListenable<List<Note>> get notes => _notes;

  @override
  ValueListenable<List<Topic>> get topics => _topics;

  @override
  ValueListenable<List<Note>> get lastDeleted => _lastDeleted;

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
        await _setNotes([
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
        await _setTopics([..._topics.value, topic]);
      case DeleteTopics(:final ids):
        final idSet = ids.toSet()..remove(Topic.uncategorisedId);
        if (idSet.isEmpty) return;
        await _setTopics([
          for (final t in _topics.value)
            if (!idSet.contains(t.id)) t,
        ]);
        if (_notes.value.any((n) => idSet.contains(n.topicId))) {
          await _setNotes([
            for (final n in _notes.value)
              idSet.contains(n.topicId)
                  ? n.copyWith(topicId: Topic.uncategorisedId)
                  : n,
          ]);
        }
    }
  }

  /// Inserts or replaces [notes] as described by [SaveNote].
  Future<void> _saveNotes(List<Note> notes) async {
    final ids = {for (final n in notes) n.id};
    if (_lastDeleted.value.any((n) => ids.contains(n.id))) {
      _lastDeleted.value = List.unmodifiable(
        _lastDeleted.value.where((n) => !ids.contains(n.id)),
      );
    }
    final topicIds = {for (final t in _topics.value) t.id};
    await _setNotes([
      for (final n in _notes.value)
        if (!ids.contains(n.id)) n,
      for (final n in notes)
        if (!n.isEmpty)
          topicIds.contains(n.topicId)
              ? n
              : n.copyWith(topicId: Topic.uncategorisedId),
    ]);
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
