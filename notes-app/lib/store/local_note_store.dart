import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../note.dart';
import 'note_store.dart';

/// Keeps notes in memory and persists them to SharedPreferences as JSON.
class LocalNoteStore extends NoteStore {
  LocalNoteStore(this._prefs) : _notes = ValueNotifier(_load(_prefs));

  static const _key = 'notes_v1';

  final SharedPreferences _prefs;
  final ValueNotifier<List<Note>> _notes;

  @override
  ValueListenable<List<Note>> get notes => _notes;

  @override
  Future<void> dispatch(NoteAction action) async {
    final next = _sorted(switch (action) {
      SaveNote(:final note) => [
        for (final n in _notes.value)
          if (n.id != note.id) n,
        if (!note.isEmpty) note,
      ],
      DeleteNote(:final id) => [
        for (final n in _notes.value)
          if (n.id != id) n,
      ],
    });
    _notes.value = next;
    await _prefs.setString(
      _key,
      jsonEncode(next.map((n) => n.toJson()).toList()),
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

  static List<Note> _sorted(List<Note> notes) => List.unmodifiable(
    notes..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );
}
