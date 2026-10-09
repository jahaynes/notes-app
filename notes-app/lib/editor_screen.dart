import 'package:flutter/material.dart';

import 'note.dart';
import 'store/note_store.dart';

/// Edits a working copy of a note and saves it when the screen is left.
/// Pops with the deleted note (for undo) if the user deletes it.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.store, required this.note});

  final NoteStore store;
  final Note note;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final Note _draft = widget.note.copy();
  late final _title = TextEditingController(text: _draft.title);
  late final _body = TextEditingController(text: _draft.body);
  bool _deleted = false;

  bool get _contentChanged =>
      _title.text != widget.note.title || _body.text != widget.note.body;

  bool get _changed =>
      _contentChanged ||
      _draft.colorIndex != widget.note.colorIndex ||
      _draft.showFull != widget.note.showFull;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save() {
    if (_deleted || !_changed) return;
    _draft
      ..title = _title.text
      ..body = _body.text;
    // Only bump the timestamp for content edits, not display tweaks.
    if (_contentChanged) _draft.updatedAt = DateTime.now();
    widget.store.upsert(_draft);
  }

  void _delete() {
    _deleted = true;
    final existed = widget.store.byId(widget.note.id) != null;
    widget.store.delete(widget.note.id);
    Navigator.of(context).pop(existed ? widget.note.copy() : null);
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
                  selected: _draft.colorIndex == i,
                  onTap: () {
                    setState(() => _draft.colorIndex = i);
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
    final bg = noteColors[_draft.colorIndex];
    final fg = bg != null ? Colors.black87 : theme.colorScheme.onSurface;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _save();
      },
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          foregroundColor: bg != null ? Colors.black87 : null,
          actions: [
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _draft.showFull = !_draft.showFull),
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    Checkbox(
                      value: _draft.showFull,
                      onChanged: (v) => setState(() => _draft.showFull = v!),
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
