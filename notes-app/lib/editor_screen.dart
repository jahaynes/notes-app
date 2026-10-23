import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'bullet_formatter.dart';
import 'note.dart';
import 'store/note_store.dart';

/// Edits a note, dispatching every change as it happens so that leaving by
/// any route (app bar, system or browser back) keeps the edits. Leaving also
/// flushes the store, so that changes it's holding back aren't kept waiting.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.store, required this.note});

  final NoteStore store;
  final Note note;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  /// The note as last sent to the store.
  late Note _note = widget.note;
  late final _title = TextEditingController(text: _note.title)
    ..addListener(_save);
  final _bulletFormatter = BulletFormatter();
  late final _body = BulletEditingController(text: _note.body)
    ..addListener(_save);

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    widget.store.flush();
    super.dispose();
  }

  void _save({String? topicId}) {
    final next = _note.copyWith(
      title: _title.text,
      body: _body.text,
      topicId: topicId,
    );
    if (next == _note) return;
    final contentChanged = next.title != _note.title || next.body != _note.body;
    // Only bump the timestamp for content edits, not moves.
    setState(
      () => _note = contentChanged
          ? next.copyWith(updatedAt: DateTime.now())
          : next,
    );
    widget.store.dispatch(SaveNote(_note));
  }

  void _delete() {
    widget.store.dispatch(DeleteNotes([_note.id]));
    context.pop();
  }

  void _pickTopic() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final topic in widget.store.topics.value)
              ListTile(
                leading: Icon(
                  widget.store.isDefault(topic)
                      ? Icons.inbox_outlined
                      : Icons.label_outline,
                ),
                title: Text(topic.name),
                trailing: topic.id == _note.topicId
                    ? const Icon(Icons.check)
                    : null,
                onTap: () {
                  _save(topicId: topic.id);
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = noteColors[_note.colorIndex];
    final fg = bg != null ? Colors.black87 : theme.colorScheme.onSurface;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: bg != null ? Colors.black87 : null,
        actions: [
          IconButton(
            tooltip: 'Topic',
            icon: const Icon(Icons.label_outline),
            onPressed: _pickTopic,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              TextField(
                controller: _title,
                autofocus: widget.note.isEmpty,
                textCapitalization: TextCapitalization.sentences,
                style: theme.textTheme.headlineSmall?.copyWith(color: fg),
                decoration: InputDecoration(
                  hintText: 'Title',
                  hintStyle: TextStyle(color: fg.withValues(alpha: 0.4)),
                  border: InputBorder.none,
                ),
                textInputAction: TextInputAction.next,
              ),
              Expanded(
                // Tab edits the text rather than moving focus.
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.tab): () =>
                        _body.value = indentBullets(_body.value),
                    const SingleActivator(
                      LogicalKeyboardKey.tab,
                      shift: true,
                    ): () =>
                        _body.value = outdentBullets(_body.value),
                  },
                  child: TextField(
                    controller: _body,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: TextInputType.multiline,
                    inputFormatters: [_bulletFormatter],
                    style: theme.textTheme.bodyLarge?.copyWith(color: fg),
                    decoration: InputDecoration(
                      hintText: 'Start writing…',
                      hintStyle: TextStyle(color: fg.withValues(alpha: 0.4)),
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
