import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'note.dart';
import 'store/note_store.dart';

/// Edits a note, dispatching every change as it happens so that leaving by
/// any route (app bar, system or browser back) keeps the edits.
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
  late final _body = TextEditingController(text: _note.body)
    ..addListener(_save);

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save({int? colorIndex, bool? showFull, String? topicId}) {
    final next = _note.copyWith(
      title: _title.text,
      body: _body.text,
      colorIndex: colorIndex,
      showFull: showFull,
      topicId: topicId,
    );
    if (next == _note) return;
    final contentChanged = next.title != _note.title || next.body != _note.body;
    // Only bump the timestamp for content edits, not display tweaks.
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

  void _pickColor() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var i = 0; i < noteColors.length; i++)
                _ColorDot(
                  color: noteColors[i],
                  selected: _note.colorIndex == i,
                  onTap: () {
                    _save(colorIndex: i);
                    Navigator.pop(sheetContext);
                  },
                ),
            ],
          ),
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
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _save(showFull: !_note.showFull),
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Checkbox(
                    value: _note.showFull,
                    onChanged: (v) => _save(showFull: v),
                    side: BorderSide(color: fg, width: 2),
                  ),
                  Text(
                    'Show in full',
                    style: theme.textTheme.labelLarge?.copyWith(color: fg),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Topic',
            icon: const Icon(Icons.label_outline),
            onPressed: _pickTopic,
          ),
          IconButton(
            tooltip: 'Color',
            icon: const Icon(Icons.palette_outlined),
            onPressed: _pickColor,
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
                child: TextField(
                  controller: _body,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  style: theme.textTheme.bodyLarge?.copyWith(color: fg),
                  decoration: InputDecoration(
                    hintText: 'Start writing…',
                    hintStyle: TextStyle(color: fg.withValues(alpha: 0.4)),
                    border: InputBorder.none,
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

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap,
      radius: 26,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color ?? scheme.surface,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: color == null
            ? Icon(Icons.format_color_reset, size: 20, color: scheme.onSurface)
            : null,
      ),
    );
  }
}
