import 'package:flutter/foundation.dart';

import '../note.dart';

/// Source of truth for notes. Listeners are notified after every change.
abstract class NoteStore extends ChangeNotifier {
  /// All notes, most recently updated first.
  List<Note> get notes;

  Note? byId(String id);

  /// Inserts or replaces [note]. Empty notes are discarded instead of saved.
  void upsert(Note note);

  void delete(String id);

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
}
