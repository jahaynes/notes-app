import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'appearance.dart';
import 'auth.dart';
import 'editor_screen.dart';
import 'login_screen.dart';
import 'note.dart';
import 'notes_screen.dart';
import 'store/http_note_store.dart';
import 'store/local_note_store.dart';
import 'store/note_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Something on screen straight away, rather than nothing until the
  // app is ready, and the error if it never gets there.
  runApp(
    const _PlainApp(
      home: Scaffold(body: Center(child: CircularProgressIndicator())),
    ),
  );
  try {
    runApp(await _startApp());
  } catch (e, stack) {
    debugPrint('Could not start: $e\n$stack');
    runApp(
      _PlainApp(
        home: _StartFailed(error: e, stack: stack),
      ),
    );
  }
}

Future<Widget> _startApp() async {
  final prefs = await SharedPreferences.getInstance();
  final client = http.Client();
  final auth = AuthSession(client, prefs);
  await auth.restore();
  return AppearanceScope(
    appearance: Appearance(prefs),
    child: LoggedInApp(
      auth: auth,
      openStore: (storage) => switch (storage) {
        OnDevice() => LocalNoteStore.open(prefs),
        // A turned-down token logs out, which goes back to the login screen.
        OnServer(:final login) => HttpNoteStore.open(
          client,
          prefs,
          login,
          onRejected: () => auth.rejected(login.token),
        ),
      },
    ),
  );
}

/// Says the app couldn't start, with the error, as there's nowhere else
/// to see it on a phone.
class _StartFailed extends StatelessWidget {
  const _StartFailed({required this.error, required this.stack});

  final Object error;
  final StackTrace stack;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          "Couldn't start\n\n$error\n\n$stack",
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ),
    ),
  );
}

/// The app showing just [home], in the picked palette, for before there are
/// notes to show.
class _PlainApp extends StatelessWidget {
  const _PlainApp({required this.home});

  final Widget home;

  @override
  Widget build(BuildContext context) {
    final palette = AppearanceScope.paletteOf(context);
    return MaterialApp(
      title: 'Noteish',
      debugShowCheckedModeBanner: false,
      theme: palette.theme(Brightness.light),
      darkTheme: palette.theme(Brightness.dark),
      home: home,
    );
  }
}

/// The app: a login screen until someone is logged in to a backend or picks
/// this device, then the notes from the store [openStore] opens for that.
/// Logging out goes back to the login screen.
class LoggedInApp extends StatefulWidget {
  const LoggedInApp({super.key, required this.auth, required this.openStore});

  final AuthSession auth;
  final Future<NoteStore> Function(Storage storage) openStore;

  @override
  State<LoggedInApp> createState() => _LoggedInAppState();
}

class _LoggedInAppState extends State<LoggedInApp> {
  /// The store for where the notes are kept, or null until that's picked.
  ({Object id, Future<NoteStore> store})? _opened;

  @override
  void initState() {
    super.initState();
    _opened = _open(widget.auth.storage);
    widget.auth.changes.addListener(_storageChanged);
  }

  @override
  void dispose() {
    widget.auth.changes.removeListener(_storageChanged);
    super.dispose();
  }

  ({Object id, Future<NoteStore> store})? _open(Storage? storage) =>
      storage == null
      ? null
      : (id: storage.id, store: widget.openStore(storage));

  void _storageChanged() {
    final storage = widget.auth.storage;
    if (storage?.id == _opened?.id) return;
    // Changes held back still go out, as the user who made them.
    _opened?.store.then((store) => store.flush()).ignore();
    setState(() => _opened = _open(storage));
  }

  @override
  Widget build(BuildContext context) => switch (_opened) {
    null => _PlainApp(home: LoginScreen(auth: widget.auth)),
    (:final id, :final store) => FutureBuilder(
      key: ValueKey(id),
      future: store,
      builder: (context, snapshot) => switch (snapshot) {
        AsyncSnapshot(:final data?) => NoteishApp(
          store: data,
          auth: widget.auth,
        ),
        AsyncSnapshot(:final error?) => _PlainApp(
          home: _OpenFailed(
            error: error,
            onRetry: () => setState(() => _opened = _open(widget.auth.storage)),
            onLogOut: widget.auth.logOut,
          ),
        ),
        _ => const _PlainApp(
          home: Scaffold(body: Center(child: CircularProgressIndicator())),
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

  /// Who's logged in to the Notes API, or that the notes are on this device,
  /// shown in the sidebar with a way back to the login screen. Null shows
  /// neither.
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
  Widget build(BuildContext context) {
    final palette = AppearanceScope.paletteOf(context);
    return MaterialApp.router(
      title: 'Noteish',
      debugShowCheckedModeBanner: false,
      theme: palette.theme(Brightness.light),
      darkTheme: palette.theme(Brightness.dark),
      routerConfig: _router,
    );
  }
}
