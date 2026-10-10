import 'package:flutter/foundation.dart';

import '../note.dart';
import '../topic.dart';

/// A change the UI asks the store to make.
sealed class NoteAction {
  const NoteAction();
}

/// Inserts or replaces [note]. Saving an empty note deletes it instead, and a
/// note whose topic no longer exists is saved to [Topic.uncategorised].
final class SaveNote extends NoteAction {
  const SaveNote(this.note);

  final Note note;
}

final class DeleteNote extends NoteAction {
  const DeleteNote(this.id);

  final String id;
}

/// Adds [topic] to the end of the topic list.
final class AddTopic extends NoteAction {
  const AddTopic(this.topic);

  final Topic topic;
}

/// Removes the topic with [id], moving its notes to [Topic.uncategorised].
/// The default topic can't be deleted.
final class DeleteTopic extends NoteAction {
  const DeleteTopic(this.id);

  final String id;
}

/// Source of truth for notes. Actions flow in through [dispatch]; the
/// resulting state flows out through [notes].
abstract class NoteStore {
  /// All notes, most recently updated first. Each change publishes a new,
  /// unmodifiable list rather than mutating the old one.
  ValueListenable<List<Note>> get notes;

  /// All topics, [Topic.uncategorised] first and the rest in the order they
  /// were added. Published the same way as [notes].
  ValueListenable<List<Topic>> get topics;

  /// The most recently deleted note, so it can be restored by saving it again.
  /// Cleared once it's restored. Not persisted.
  ValueListenable<Note?> get lastDeleted;

  /// Applies [action]. Completes once the change has been persisted.
  Future<void> dispatch(NoteAction action);

  Note? byId(String id) => notes.value.where((n) => n.id == id).firstOrNull;

  /// Notes matching [query], limited to the topic [topicId] if given.
  List<Note> search(String query, {String? topicId}) {
    final q = query.trim().toLowerCase();
    return notes.value
        .where(
          (n) =>
              (topicId == null || n.topicId == topicId) &&
              (n.title.toLowerCase().contains(q) ||
                  n.body.toLowerCase().contains(q)),
        )
        .toList();
  }
}
