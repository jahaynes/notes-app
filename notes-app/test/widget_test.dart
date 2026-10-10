import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteish/store/local_note_store.dart';
import 'package:go_router/go_router.dart';
import 'package:noteish/editor_screen.dart';
import 'package:noteish/main.dart';
import 'package:noteish/note.dart';
import 'package:noteish/store/note_store.dart';
import 'package:noteish/topic.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<NoteStore> _freshStore() async {
  SharedPreferences.setMockInitialValues({});
  return LocalNoteStore(await SharedPreferences.getInstance());
}

void main() {
  test('store persists, and drops empty notes', () async {
    final store = await _freshStore();
    final a = Note.create().copyWith(title: 'A');
    final b = Note.create().copyWith(title: 'B');
    await store.dispatch(SaveNote(a));
    await store.dispatch(SaveNote(b));
    await store.dispatch(SaveNote(Note.create())); // empty, ignored

    expect(store.notes.value.map((n) => n.title), ['B', 'A']);
    expect(store.search('a').single.title, 'A');

    // Reload from the same prefs.
    final reloaded = LocalNoteStore(await SharedPreferences.getInstance());
    expect(reloaded.notes.value.length, 2);
  });

  test('topics persist, and the default topic is undeletable', () async {
    final store = await _freshStore();
    expect(store.topics.value, [Topic.uncategorised]);

    final work = Topic.create('Work');
    final home = Topic.create('Home');
    await store.dispatch(AddTopic(work));
    await store.dispatch(AddTopic(home));
    await store.dispatch(DeleteTopic(work.id));
    await store.dispatch(DeleteTopic(Topic.uncategorised.id)); // ignored

    expect(store.topics.value, [Topic.uncategorised, home]);

    final reloaded = LocalNoteStore(await SharedPreferences.getInstance());
    expect(reloaded.topics.value, [Topic.uncategorised, home]);
  });

  testWidgets('add and delete topics from the sidebar', (tester) async {
    final store = await _freshStore();
    await tester.pumpWidget(NoteishApp(store: store));
    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();

    expect(find.text('Uncategorised'), findsOneWidget);
    expect(find.byTooltip('Delete topic'), findsNothing);

    await tester.tap(find.text('Add topic'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Recipes ');
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Recipes'), findsOneWidget);
    expect(store.topics.value.last.name, 'Recipes');

    await tester.tap(find.byTooltip('Delete topic'));
    await tester.pumpAndSettle();
    expect(find.text('Recipes'), findsNothing);
    expect(store.topics.value, [Topic.uncategorised]);
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
    expect(store.notes.value.single.body, 'eggs, milk');

    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(store.notes.value, isEmpty);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Groceries'), findsOneWidget);
  });

  testWidgets('show in full removes truncation on the overview', (
    tester,
  ) async {
    final store = await _freshStore();
    final body = List.generate(20, (i) => 'line $i').join('\n');
    store.dispatch(SaveNote(Note.create().copyWith(body: body)));
    await tester.pumpWidget(NoteishApp(store: store));

    expect(tester.widget<Text>(find.text(body)).maxLines, 8);

    await tester.tap(find.text(body));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show in full'));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(store.notes.value.single.showFull, isTrue);
    expect(tester.widget<Text>(find.text(body)).maxLines, isNull);

    final reloaded = LocalNoteStore(await SharedPreferences.getInstance());
    expect(reloaded.notes.value.single.showFull, isTrue);
  });

  testWidgets('edits survive leaving via a URL change (browser back)', (
    tester,
  ) async {
    final store = await _freshStore();
    await tester.pumpWidget(NoteishApp(store: store));

    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Kept');

    // Browser back replaces the route stack rather than popping the editor.
    GoRouter.of(tester.element(find.byType(EditorScreen))).go('/');
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsNothing);
    expect(find.text('Kept'), findsOneWidget);
    expect(store.notes.value.single.title, 'Kept');
  });
}
