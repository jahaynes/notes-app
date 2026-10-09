import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../note.dart';
import 'note_store.dart';

/// Holds all notes in memory and persists them to SharedPreferences as JSON.
class LocalNoteStore extends NoteStore {
  LocalNoteStore(this._prefs) {
    final raw = _prefs.getString(_key);
    if (raw != null) {
      final list = jsonDecode(raw) as List<dynamic>;
      _notes.addAll(list.map((e) => Note.fromJson(e as Map<String, dynamic>)));
    }
  }

  static const _key = 'notes_v1';

  final SharedPreferences _prefs;
  final List<Note> _notes = [];

  @override
  List<Note> get notes =>
      [..._notes]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Note? byId(String id) => _notes.where((n) => n.id == id).firstOrNull;

  @override
  void upsert(Note note) {
    final i = _notes.indexWhere((n) => n.id == note.id);
    if (note.isEmpty) {
      if (i != -1) _notes.removeAt(i);
    } else if (i == -1) {
      _notes.add(note);
    } else {
      _notes[i] = note;
    }
    _save();
  }

  @override
  void delete(String id) {
    _notes.removeWhere((n) => n.id == id);
    _save();
  }

  void _save() {
    _prefs.setString(_key, jsonEncode(_notes.map((n) => n.toJson()).toList()));
    notifyListeners();
  }
}
