import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'store/local_note_store.dart';
import 'store/note_store.dart';
import 'notes_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(NoteishApp(store: LocalNoteStore(prefs)));
}

class NoteishApp extends StatelessWidget {
  const NoteishApp({super.key, required this.store});

  final NoteStore store;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFF2B33D);
    return MaterialApp(
      title: 'Noteish',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: NotesScreen(store: store),
    );
  }
}
