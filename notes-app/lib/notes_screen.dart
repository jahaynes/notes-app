import 'package:flutter/material.dart';

import 'editor_screen.dart';
import 'note.dart';
import 'store/note_store.dart';

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

  NoteStore get store => widget.store;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _open(Note note) async {
    final deleted = await Navigator.of(context).push<Note>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(store: store, note: note),
      ),
    );
    if (deleted != null && mounted) _showUndo(deleted);
  }

  void _delete(Note note) {
    final backup = note.copy();
    store.delete(note.id);
    _showUndo(backup);
  }

  void _showUndo(Note deleted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Note deleted'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => store.upsert(deleted),
          ),
        ),
      );
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
            : const Text('Noteish'),
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
          if (!_searching)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: () => setState(() => _searching = true),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(Note.create()),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New note'),
      ),
      body: Row(
        children: [
          _Sidebar(open: _sidebarOpen),
          Expanded(
            child: ListenableBuilder(
              listenable: store,
              builder: (context, _) {
                final notes = store.search(_searchController.text);
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
                              onTap: () => _open(note),
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

/// Hideable side panel; empty for now.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: open ? 240 : 0,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: open
            ? Border(right: BorderSide(color: scheme.outlineVariant))
            : null,
      ),
      child: const SizedBox.shrink(),
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
