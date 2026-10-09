import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'note.dart';

/// Holds all notes in memory and persists them to SharedPreferences as JSON.
class NoteStore extends ChangeNotifier {
  NoteStore(this._prefs) {
    final raw = _prefs.getString(_key);
    if (raw != null) {
      final list = jsonDecode(raw) as List<dynamic>;
      _notes.addAll(list.map((e) => Note.fromJson(e as Map<String, dynamic>)));
    }
  }

  static const _key = 'notes_v1';
  static const _uuid = Uuid();

  final SharedPreferences _prefs;
  final List<Note> _notes = [];

  List<Note> get notes =>
      [..._notes]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  List<Note> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return notes;
    return notes
        .where(
          (n) =>
              n.title.toLowerCase().contains(q) ||
              n.body.toLowerCase().contains(q),
        )
        .toList();
  }

  Note? byId(String id) => _notes.where((n) => n.id == id).firstOrNull;

  Note newNote() => Note(id: _uuid.v4());

  /// Inserts or replaces [note]. Empty notes are discarded instead of saved.
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

  void delete(String id) {
    _notes.removeWhere((n) => n.id == id);
    _save();
  }

  void _save() {
    _prefs.setString(_key, jsonEncode(_notes.map((n) => n.toJson()).toList()));
    notifyListeners();
  }
}
