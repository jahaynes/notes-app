import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'editor_screen.dart';
import 'note.dart';
import 'notes_screen.dart';
import 'store/http_note_store.dart';
import 'store/local_note_store.dart';
import 'store/note_store.dart';

/// The Notes API base URL, e.g. `--dart-define=NOTES_API=http://127.0.0.1:8081/`.
/// Notes are kept on the device when it isn't set.
const _notesApi = String.fromEnvironment('NOTES_API');

/// The user to sign in to the Notes API as, e.g.
/// `--dart-define=NOTES_USER=<uuid>`. The device's own user when not set.
const _notesUser = String.fromEnvironment('NOTES_USER');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final NoteStore store = _notesApi.isEmpty
      ? await LocalNoteStore.open(prefs)
      : await HttpNoteStore.open(
          http.Client(),
          Uri.parse(_notesApi),
          prefs,
          userId: _notesUser.isEmpty ? null : _notesUser,
        );
  runApp(NoteishApp(store: store));
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
            builder: (_, state) {
              final topicId = state.uri.queryParameters['topic'];
              return EditorScreen(
                store: widget.store,
                note: Note.create(
                  topicId: topicId ?? widget.store.defaultTopic.id,
                ),
              );
            },
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
