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

/// Deletes the notes with [ids], remembering them in [NoteStore.lastDeleted]
/// in place of whatever was deleted before.
final class DeleteNotes extends NoteAction {
  const DeleteNotes(this.ids);

  final Iterable<String> ids;
}

/// Moves the notes with [ids] into the topic [topicId], leaving their
/// timestamps alone.
final class MoveNotes extends NoteAction {
  const MoveNotes(this.ids, this.topicId);

  final Iterable<String> ids;
  final String topicId;
}

/// Restores every note in [NoteStore.lastDeleted].
final class UndoDelete extends NoteAction {
  const UndoDelete();
}

/// Adds [topic] to the end of the topic list.
final class AddTopic extends NoteAction {
  const AddTopic(this.topic);

  final Topic topic;
}

/// Removes the topics with [ids], moving their notes to
/// [Topic.uncategorised]. The default topic can't be deleted.
final class DeleteTopics extends NoteAction {
  const DeleteTopics(this.ids);

  final Iterable<String> ids;
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

  /// The notes removed by the most recent [DeleteNotes], until they're
  /// restored. Not persisted.
  ValueListenable<List<Note>> get lastDeleted;

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
