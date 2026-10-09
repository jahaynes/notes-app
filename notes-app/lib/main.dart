import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'editor_screen.dart';
import 'note.dart';
import 'notes_screen.dart';
import 'store/local_note_store.dart';
import 'store/note_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(NoteishApp(store: LocalNoteStore(prefs)));
}

class NoteishApp extends StatefulWidget {
  const NoteishApp({super.key, required this.store});

  final NoteStore store;

  @override
  State<NoteishApp> createState() => _NoteishAppState();
}

class _NoteishAppState extends State<NoteishApp> {
  // Router-based navigation gives each screen a browser history entry, so the
  // browser's back button moves between screens instead of leaving the app.
  late final _router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => NotesScreen(store: widget.store),
        routes: [
          GoRoute(
            path: 'new',
            builder: (_, _) =>
                EditorScreen(store: widget.store, note: Note.create()),
          ),
          GoRoute(
            path: 'note/:id',
            redirect: (_, state) =>
                widget.store.byId(state.pathParameters['id']!) == null
                ? '/'
                : null,
            builder: (_, state) => EditorScreen(
              store: widget.store,
              note: widget.store.byId(state.pathParameters['id']!)!,
            ),
          ),
        ],
      ),
    ],
  );

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFF2B33D);
    return MaterialApp.router(
      title: 'Noteish',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}
