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

  /// The topic whose notes are shown, or null to show all notes.
  String? _topicId = Topic.uncategorisedId;

  NoteStore get store => widget.store;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _delete(Note note) => store.dispatch(DeleteNote(note.id));

  /// The selected topic, or null when showing all notes.
  Topic? get _selectedTopic => _topicId == null
      ? null
      : store.topics.value.firstWhere(
          (t) => t.id == _topicId,
          orElse: () => Topic.uncategorised,
        );

  Future<void> _deleteSelectedTopic() async {
    final topic = _selectedTopic;
    if (topic == null || topic.isDefault) return;
    final count = store.search('', topicId: topic.id).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${topic.name}"?'),
        content: Text(
          count == 0
              ? 'This topic has no notes.'
              : 'Its ${count == 1 ? 'note' : '$count notes'} will be moved '
                    'to Uncategorised.',
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
    store.dispatch(DeleteTopic(topic.id));
    // Its notes move to Uncategorised, so follow them there.
    setState(() => _topicId = Topic.uncategorisedId);
  }

  void _stopSearching() {
    setState(() {
      _searching = false;
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
            builder: (context, deleted, _) => deleted == null
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.restore_from_trash_outlined),
                    tooltip: 'Undo delete',
                    onPressed: () => store.dispatch(SaveNote(deleted)),
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
              onPressed: _deleteSelectedTopic,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            context.go(_topicId == null ? '/new' : '/new?topic=$_topicId'),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New note'),
      ),
      body: Row(
        children: [
          _Sidebar(
            store: store,
            open: _sidebarOpen,
            selectedTopicId: _topicId,
            onSelect: (id) => setState(() => _topicId = id),
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
                  return _EmptyState(
                    searching: _searchController.text.isNotEmpty,
                  );
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.maxWidth / 240).floor().clamp(
                      1,
                      5,
                    );
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                      child: _Masonry(
                        columns: columns,
                        children: [
                          for (final note in notes)
                            _NoteCard(
                              key: ValueKey(note.id),
                              note: note,
                              onTap: () => context.go('/note/${note.id}'),
                              onLongPress: () => _showActions(note),
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
      ),
    );
  }

  void _showActions(Note note) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(sheetContext);
                _delete(note);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Hideable side panel listing the topics.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.store,
    required this.open,
    required this.selectedTopicId,
    required this.onSelect,
  });

  static const _width = 240.0;

  final NoteStore store;
  final bool open;

  /// The selected topic's id, or null when "(All)" is selected.
  final String? selectedTopicId;
  final ValueChanged<String?> onSelect;

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
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: _width,
          maxWidth: _width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Topics',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
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
                          onTap: () => onSelect(null),
                        ),
                        for (final topic in topics)
                          ListTile(
                            key: ValueKey(topic.id),
                            dense: true,
                            selected: topic.id == selectedTopicId,
                            onTap: () => onSelect(topic.id),
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
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Add topic'),
                onTap: () => _addTopic(context),
              ),
            ],
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
    super.key,
    required this.note,
    required this.onTap,
    required this.onLongPress,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = noteColors[note.colorIndex];
    // Pastel note colors need dark text regardless of app brightness.
    final fg = bg != null ? Colors.black87 : theme.colorScheme.onSurface;

    return Card(
      color: bg ?? theme.colorScheme.surfaceContainerHigh,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(14),
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
              if (note.title.trim().isNotEmpty && note.body.trim().isNotEmpty)
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
