import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'note.dart';
import 'store/note_store.dart';
import 'topic.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.store});

  final NoteStore store;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _searchController = TextEditingController();
  bool _searching = false;
  bool _sidebarOpen = false;

  /// Whether the sidebar was opened just for a drag, to be closed after it.
  bool _sidebarOpenedForDrag = false;

  /// The topic whose notes are shown, or null to show all notes.
  String? _topicId = Topic.uncategorisedId;

  /// Ids of the notes, or of the topics, ticked for deletion. Only one kind
  /// is ticked at a time; either being non-empty means selection mode.
  final _selectedNotes = <String>{};
  final _selectedTopics = <String>{};

  bool get _selecting =>
      _selectedNotes.isNotEmpty || _selectedTopics.isNotEmpty;

  NoteStore get store => widget.store;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// A long-press on [note] ticks it and starts dragging every ticked note,
  /// showing the sidebar so there's somewhere to drop them.
  void _startDrag(Note note) => setState(() {
    _selectedTopics.clear();
    _selectedNotes.add(note.id);
    if (!_sidebarOpen) _sidebarOpen = _sidebarOpenedForDrag = true;
  });

  void _endDrag() {
    if (!_sidebarOpenedForDrag) return;
    setState(() => _sidebarOpen = _sidebarOpenedForDrag = false);
  }

  void _moveNotes(Set<String> ids, String topicId) {
    store.dispatch(MoveNotes(ids, topicId));
    _clearSelection();
    // The dragged card may leave the list, which skips its onDragEnd.
    _endDrag();
  }

  void _openNote(Note note) {
    // Leaving to edit a note abandons any topics ticked for deletion.
    if (_selectedTopics.isNotEmpty) setState(_selectedTopics.clear);
    context.go('/note/${note.id}');
  }

  void _toggleNote(Note note) => setState(() {
    _selectedTopics.clear();
    if (!_selectedNotes.remove(note.id)) _selectedNotes.add(note.id);
  });

  void _toggleTopic(Topic topic) => setState(() {
    _selectedNotes.clear();
    if (!_selectedTopics.remove(topic.id)) _selectedTopics.add(topic.id);
  });

  void _clearSelection() => setState(() {
    _selectedNotes.clear();
    _selectedTopics.clear();
  });

  void _deleteSelected() {
    if (_selectedNotes.isNotEmpty) {
      store.dispatch(DeleteNotes(_selectedNotes.toList()));
      _clearSelection();
    } else {
      _deleteTopics([
        for (final t in store.topics.value)
          if (_selectedTopics.contains(t.id)) t,
      ]);
    }
  }

  /// The selected topic, or null when showing all notes.
  Topic? get _selectedTopic => _topicId == null
      ? null
      : store.topics.value.firstWhere(
          (t) => t.id == _topicId,
          orElse: () => Topic.uncategorised,
        );

  /// Deletes [topics] once the user confirms, moving their notes to
  /// Uncategorised. There's no undo for topics, hence the prompt.
  Future<void> _deleteTopics(List<Topic> topics) async {
    if (topics.isEmpty) return;
    final one = topics.length == 1;
    final ids = {for (final t in topics) t.id};
    final count = store.notes.value
        .where((n) => ids.contains(n.topicId))
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          one
              ? 'Delete "${topics.single.name}"?'
              : 'Delete ${topics.length} topics?',
        ),
        content: Text(
          count == 0
              ? (one
                    ? 'This topic has no notes.'
                    : 'These topics have no notes.')
              : '${one ? 'Its' : 'Their'} ${count == 1 ? 'note' : '$count notes'} '
                    'will be moved to Uncategorised.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    store.dispatch(DeleteTopics(ids));
    setState(() {
      _selectedTopics.clear();
      // If the shown topic went, follow its notes to Uncategorised.
      if (ids.contains(_topicId)) _topicId = Topic.uncategorisedId;
    });
  }

  void _stopSearching() {
    setState(() {
      _searching = false;
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Back leaves selection mode, then search, before it leaves the screen.
    return PopScope(
      canPop: !_selecting && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _clearSelection();
        } else {
          _stopSearching();
        }
      },
      child: Scaffold(
        appBar: _selecting ? _selectionAppBar() : _appBar(),
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton.extended(
                // No hero: the editor has no FAB to fly to, and the button can
                // briefly exist twice when selection mode ends mid-animation.
                heroTag: null,
                onPressed: () => context.go(
                  _topicId == null ? '/new' : '/new?topic=$_topicId',
                ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('New note'),
              ),
        body: _body(),
      ),
    );
  }

  AppBar _selectionAppBar() => AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      tooltip: 'Cancel selection',
      onPressed: _clearSelection,
    ),
    title: Text(
      _selectedNotes.isNotEmpty
          ? '${_selectedNotes.length} selected'
          : '${_selectedTopics.length} '
                '${_selectedTopics.length == 1 ? 'topic' : 'topics'} selected',
    ),
    actions: [
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: _selectedNotes.isNotEmpty
            ? 'Delete selected'
            : 'Delete selected topics',
        onPressed: _deleteSelected,
      ),
    ],
  );

  AppBar _appBar() => AppBar(
    title: _searching
        ? TextField(
            controller: _searchController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Search notes',
              border: InputBorder.none,
            ),
            onChanged: (_) => setState(() {}),
          )
        : ValueListenableBuilder(
            valueListenable: store.topics,
            builder: (context, _, _) =>
                Text(_selectedTopic?.name ?? 'All notes'),
          ),
    leading: _searching
        ? IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _stopSearching,
          )
        : IconButton(
            icon: const Icon(Icons.menu),
            tooltip: _sidebarOpen ? 'Hide sidebar' : 'Show sidebar',
            onPressed: () => setState(() => _sidebarOpen = !_sidebarOpen),
          ),
    actions: [
      ValueListenableBuilder(
        valueListenable: store.lastDeleted,
        builder: (context, deleted, _) => deleted.isEmpty
            ? const SizedBox.shrink()
            : IconButton(
                icon: const Icon(Icons.restore_from_trash_outlined),
                tooltip: 'Undo delete',
                onPressed: () => store.dispatch(const UndoDelete()),
              ),
      ),
      if (!_searching)
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search',
          onPressed: () => setState(() => _searching = true),
        ),
      if (!_searching && !(_selectedTopic?.isDefault ?? true))
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete topic',
          onPressed: () => _deleteTopics([_selectedTopic!]),
        ),
    ],
  );

  Widget _body() => Row(
    children: [
      _Sidebar(
        store: store,
        open: _sidebarOpen,
        selectedTopicId: _topicId,
        checkedTopicIds: _selectedTopics,
        onDropNotes: _moveNotes,
        onToggle: _toggleTopic,
        onSelect: (id) => setState(() {
          _topicId = id;
          // Don't let notes that are no longer shown stay ticked.
          _selectedNotes.clear();
          _selectedTopics.clear();
        }),
      ),
      Expanded(
        child: ListenableBuilder(
          listenable: store.notes,
          builder: (context, _) {
            final notes = store.search(
              _searchController.text,
              topicId: _topicId,
            );
            if (notes.isEmpty) {
              return _EmptyState(searching: _searchController.text.isNotEmpty);
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                // Aim for 240-wide cards, but fit two side by side on a phone
                // as long as each gets at least 150.
                final width = constraints.maxWidth;
                final columns = width < 2 * 150
                    ? 1
                    : (width / 240).floor().clamp(2, 5);
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  child: _Masonry(
                    columns: columns,
                    children: [
                      for (final note in notes)
                        _DraggableNote(
                          key: ValueKey(note.id),
                          // Dragging carries the ticked notes along with this one.
                          ids: {..._selectedNotes, note.id},
                          onDragStarted: () => _startDrag(note),
                          onDragEnd: _endDrag,
                          child: _NoteCard(
                            note: note,
                            selected: _selectedNotes.isNotEmpty
                                ? _selectedNotes.contains(note.id)
                                : null,
                            onTap: _selectedNotes.isNotEmpty
                                ? () => _toggleNote(note)
                                : () => _openNote(note),
                          ),
                        ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    ],
  );
}

/// Hideable side panel listing the topics.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.store,
    required this.open,
    required this.selectedTopicId,
    required this.onSelect,
    required this.checkedTopicIds,
    required this.onToggle,
    required this.onDropNotes,
  });

  static const _width = 240.0;

  final NoteStore store;
  final bool open;

  /// The selected topic's id, or null when "(All)" is selected.
  final String? selectedTopicId;
  final ValueChanged<String?> onSelect;

  /// Ids of the topics ticked for deletion. Non-empty means selection mode.
  final Set<String> checkedTopicIds;

  /// Ticks or unticks a topic for deletion.
  final ValueChanged<Topic> onToggle;

  /// Moves notes dropped on a topic into it.
  final void Function(Set<String> noteIds, String topicId) onDropNotes;

  Future<void> _addTopic(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _AddTopicDialog(),
    );
    if (name == null) return;
    final topic = Topic.create(name);
    store.dispatch(AddTopic(topic));
    onSelect(topic.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selecting = checkedTopicIds.isNotEmpty;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: open ? _width : 0,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        border: open
            ? Border(right: BorderSide(color: scheme.outlineVariant))
            : null,
      ),
      // The background is a Material so the list tiles' ink shows on it.
      child: Material(
        color: scheme.surfaceContainerLow,
        // Lay out at full width so the contents slide rather than squash while
        // the panel animates.
        // When hidden, keep the clipped-away contents out of keyboard focus
        // and screen readers.
        child: ExcludeFocus(
          excluding: !open,
          child: ExcludeSemantics(
            excluding: !open,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: _width,
              maxWidth: _width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Topics',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: 'Add topic',
                          onPressed: () => _addTopic(context),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: store.topics,
                      builder: (context, topics, _) => ListTileTheme(
                        selectedColor: scheme.onSecondaryContainer,
                        selectedTileColor: scheme.secondaryContainer,
                        child: ListView(
                          children: [
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.notes),
                              title: const Text('(All)'),
                              selected: selectedTopicId == null,
                              enabled: !selecting,
                              onTap: () => onSelect(null),
                            ),
                            for (final topic in topics)
                              DragTarget<_NoteDrag>(
                                key: ValueKey(topic.id),
                                onAcceptWithDetails: (details) =>
                                    onDropNotes(details.data.ids, topic.id),
                                builder: (context, candidates, _) => ListTile(
                                  dense: true,
                                  // Highlight the topic a dragged note is over.
                                  tileColor: candidates.isEmpty
                                      ? null
                                      : scheme.primaryContainer,
                                  selected: topic.id == selectedTopicId,
                                  // The default topic can't be ticked for deletion.
                                  enabled: !(selecting && topic.isDefault),
                                  onTap: selecting
                                      ? () => onToggle(topic)
                                      : () => onSelect(topic.id),
                                  onLongPress: topic.isDefault
                                      ? null
                                      : () => onToggle(topic),
                                  trailing: selecting && !topic.isDefault
                                      ? Checkbox(
                                          value: checkedTopicIds.contains(
                                            topic.id,
                                          ),
                                          onChanged: (_) => onToggle(topic),
                                        )
                                      : null,
                                  leading: Icon(
                                    topic.isDefault
                                        ? Icons.inbox_outlined
                                        : Icons.label_outline,
                                  ),
                                  title: Text(
                                    topic.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for a topic name; pops with the trimmed name, or null if cancelled.
class _AddTopicDialog extends StatefulWidget {
  const _AddTopicDialog();

  @override
  State<_AddTopicDialog> createState() => _AddTopicDialogState();
}

class _AddTopicDialogState extends State<_AddTopicDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _trimmed => _name.text.trim();

  void _submit() {
    if (_trimmed.isNotEmpty) Navigator.pop(context, _trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New topic'),
      content: TextField(
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Name'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _trimmed.isEmpty ? null : _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// What's carried while dragging notes: the ids of the notes being moved.
class _NoteDrag {
  const _NoteDrag(this.ids);

  final Set<String> ids;
}

/// Lets [child] be dragged after a long-press, so a plain drag still scrolls.
class _DraggableNote extends StatelessWidget {
  const _DraggableNote({
    super.key,
    required this.ids,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.child,
  });

  final Set<String> ids;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = ids.length;
    return LongPressDraggable<_NoteDrag>(
      data: _NoteDrag(ids),
      onDragStarted: onDragStarted,
      onDragEnd: (_) => onDragEnd(),
      feedback: Material(
        elevation: 6,
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.drive_file_move_outline,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                count == 1 ? 'Move note' : 'Move $count notes',
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );
  }
}

/// Distributes children round-robin across [columns] for a staggered look.
class _Masonry extends StatelessWidget {
  const _Masonry({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var c = 0; c < columns; c++)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = c; i < children.length; i += columns)
                  Padding(padding: const EdgeInsets.all(4), child: children[i]),
              ],
            ),
          ),
      ],
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.selected,
    required this.onTap,
  });

  final Note note;

  /// Whether the card is ticked, or null when not in selection mode.
  final bool? selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = noteColors[note.colorIndex];
    // Pastel note colors need dark text regardless of app brightness.
    final fg = bg != null ? Colors.black87 : theme.colorScheme.onSurface;

    final selected = this.selected;

    return Card(
      color: bg ?? theme.colorScheme.surfaceContainerHigh,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: selected == true
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.primary, width: 3),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Padding(
              // Leave room for the checkbox in selection mode.
              padding: EdgeInsets.fromLTRB(
                14,
                14,
                selected == null ? 14 : 44,
                14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (note.title.trim().isNotEmpty)
                    Text(
                      note.title,
                      maxLines: note.showFull ? null : 2,
                      overflow: note.showFull ? null : TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (note.title.trim().isNotEmpty &&
                      note.body.trim().isNotEmpty)
                    const SizedBox(height: 6),
                  if (note.body.trim().isNotEmpty)
                    Text(
                      note.body,
                      maxLines: note.showFull ? null : 8,
                      overflow: note.showFull ? null : TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                    ),
                  const SizedBox(height: 10),
                  Text(
                    _formatDate(note.updatedAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: fg.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            if (selected != null)
              Positioned(
                top: 2,
                right: 2,
                child: Checkbox(
                  value: selected,
                  onChanged: (_) => onTap(),
                  side: BorderSide(color: fg, width: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            searching ? Icons.search_off : Icons.sticky_note_2_outlined,
            size: 64,
            color: color,
          ),
          const SizedBox(height: 12),
          Text(
            searching ? 'No matching notes' : 'No notes yet',
            style: TextStyle(color: color),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime d) {
  final now = DateTime.now();
  final diff = now.difference(d);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final base = '${months[d.month - 1]} ${d.day}';
  return d.year == now.year ? base : '$base, ${d.year}';
}
