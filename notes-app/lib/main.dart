import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth.dart';
import 'editor_screen.dart';
import 'login_screen.dart';
import 'note.dart';
import 'notes_screen.dart';
import 'store/http_note_store.dart';
import 'store/local_note_store.dart';
import 'store/note_store.dart';

/// The Notes API base URL, e.g. `--dart-define=NOTES_API=http://127.0.0.1:8081/`.
/// Notes are kept on the device when it isn't set.
const _notesApi = String.fromEnvironment('NOTES_API');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  if (_notesApi.isEmpty) {
    runApp(NoteishApp(store: await LocalNoteStore.open(prefs)));
    return;
  }
  final client = http.Client();
  final baseUri = Uri.parse(_notesApi);
  final auth = AuthSession(client, baseUri, prefs);
  await auth.restore();
  runApp(
    LoggedInApp(
      auth: auth,
      openStore: (login) => HttpNoteStore.open(client, baseUri, prefs, login),
    ),
  );
}

ThemeData _theme(Brightness brightness) => ThemeData(
  colorSchemeSeed: const Color(0xFFF2B33D),
  brightness: brightness,
  useMaterial3: true,
);

MaterialApp _plainApp(Widget home) => MaterialApp(
  title: 'Noteish',
  debugShowCheckedModeBanner: false,
  theme: _theme(Brightness.light),
  darkTheme: _theme(Brightness.dark),
  home: home,
);

/// The app against the Notes API: a login screen until someone is logged
/// in, then their notes from the store [openStore] opens for them. Logging
/// out goes back to the login screen.
class LoggedInApp extends StatefulWidget {
  const LoggedInApp({super.key, required this.auth, required this.openStore});

  final AuthSession auth;
  final Future<NoteStore> Function(Login login) openStore;

  @override
  State<LoggedInApp> createState() => _LoggedInAppState();
}

class _LoggedInAppState extends State<LoggedInApp> {
  /// The logged-in user's store, or null when logged out.
  ({String userId, Future<NoteStore> store})? _opened;

  @override
  void initState() {
    super.initState();
    _opened = _open(widget.auth.login);
    widget.auth.account.addListener(_loginChanged);
  }

  @override
  void dispose() {
    widget.auth.account.removeListener(_loginChanged);
    super.dispose();
  }

  ({String userId, Future<NoteStore> store})? _open(Login? login) =>
      login == null
      ? null
      : (userId: login.userId, store: widget.openStore(login));

  void _loginChanged() {
    final login = widget.auth.login;
    if (login?.userId == _opened?.userId) return;
    // Changes held back still go out, as the user who made them.
    _opened?.store.then((store) => store.flush()).ignore();
    setState(() => _opened = _open(login));
  }

  @override
  Widget build(BuildContext context) => switch (_opened) {
    null => _plainApp(LoginScreen(auth: widget.auth)),
    (:final userId, :final store) => FutureBuilder(
      key: ValueKey(userId),
      future: store,
      builder: (context, snapshot) => switch (snapshot) {
        AsyncSnapshot(:final data?) => NoteishApp(
          store: data,
          auth: widget.auth,
        ),
        AsyncSnapshot(:final error?) => _plainApp(
          _OpenFailed(
            error: error,
            onRetry: () => setState(() => _opened = _open(widget.auth.login)),
            onLogOut: widget.auth.logOut,
          ),
        ),
        _ => _plainApp(
          const Scaffold(body: Center(child: CircularProgressIndicator())),
        ),
      },
    ),
  };
}

/// Says the logged-in user's notes couldn't be loaded.
class _OpenFailed extends StatelessWidget {
  const _OpenFailed({
    required this.error,
    required this.onRetry,
    required this.onLogOut,
  });

  final Object error;
  final VoidCallback onRetry;
  final VoidCallback onLogOut;

  @override
  Widget build(BuildContext context) {
    debugPrint('Could not load notes: $error');
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Couldn't load your notes"),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(onPressed: onLogOut, child: const Text('Log out')),
                const SizedBox(width: 8),
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class NoteishApp extends StatefulWidget {
  const NoteishApp({super.key, required this.store, this.auth});

  final NoteStore store;

  /// Who's logged in to the Notes API, shown in the sidebar with a way to
  /// log out, or null when notes are kept on the device.
  final AuthSession? auth;

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
        builder: (_, _) => NotesScreen(store: widget.store, auth: widget.auth),
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
            // Fetches the note first, as the editor works on the copy it
            // opens with. Falls back to the copy held here if that fails.
            redirect: (_, state) async {
              final id = state.pathParameters['id']!;
              try {
                await widget.store.refreshNote(id);
              } on Exception catch (e) {
                debugPrint('Opening note $id without refreshing it: $e');
              }
              return widget.store.byId(id) == null ? '/' : null;
            },
            builder: (_, state) => EditorScreen(
              store: widget.store,
              note: widget.store.byId(state.pathParameters['id']!)!,
            ),
          ),
        ],
      ),
    ],
  );

  /// Sends held-back changes when the app is hidden, e.g. its tab is
  /// switched away from or closed, as it may not get another chance.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: widget.store.flush);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Noteish',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    routerConfig: _router,
  );
}
