import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteish/store/local_note_store.dart';
import 'package:noteish/main.dart';
import 'package:noteish/note.dart';
import 'package:noteish/store/note_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<NoteStore> _freshStore() async {
  SharedPreferences.setMockInitialValues({});
  return LocalNoteStore(await SharedPreferences.getInstance());
}

void main() {
  test('store persists, and drops empty notes', () async {
    final store = await _freshStore();
    final a = Note.create()..title = 'A';
    final b = Note.create()..title = 'B';
    store.upsert(a);
    store.upsert(b);
    store.upsert(Note.create()); // empty, ignored

    expect(store.notes.map((n) => n.title), ['B', 'A']);
    expect(store.search('a').single.title, 'A');

    // Reload from the same prefs.
    final reloaded = LocalNoteStore(await SharedPreferences.getInstance());
    expect(reloaded.notes.length, 2);
  });

  testWidgets('create, edit, and delete a note with undo', (tester) async {
    final store = await _freshStore();
    await tester.pumpWidget(NoteishApp(store: store));
    expect(find.text('No notes yet'), findsOneWidget);

    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Groceries');
    await tester.enterText(find.byType(TextField).last, 'eggs, milk');
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
    expect(store.notes.single.body, 'eggs, milk');

    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(store.notes, isEmpty);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Groceries'), findsOneWidget);
  });

  testWidgets('show in full removes truncation on the overview', (
    tester,
  ) async {
    final store = await _freshStore();
    final body = List.generate(20, (i) => 'line $i').join('\n');
    store.upsert(Note.create()..body = body);
    await tester.pumpWidget(NoteishApp(store: store));

    expect(tester.widget<Text>(find.text(body)).maxLines, 8);

    await tester.tap(find.text(body));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show in full'));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(store.notes.single.showFull, isTrue);
    expect(tester.widget<Text>(find.text(body)).maxLines, isNull);

    final reloaded = LocalNoteStore(await SharedPreferences.getInstance());
    expect(reloaded.notes.single.showFull, isTrue);
  });
}
