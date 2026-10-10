import 'package:flutter/gestures.dart';
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
    await store.dispatch(DeleteTopics([work.id]));
    await store.dispatch(DeleteTopics([Topic.uncategorisedId])); // ignored

    expect(store.topics.value, [Topic.uncategorised, home]);

    final reloaded = LocalNoteStore(await SharedPreferences.getInstance());
    expect(reloaded.topics.value, [Topic.uncategorised, home]);
  });

  testWidgets('add and delete topics from the sidebar', (tester) async {
    final store = await _freshStore();
    await tester.pumpWidget(NoteishApp(store: store));
    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '(All)'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Uncategorised'), findsOneWidget);
    expect(find.byTooltip('Delete topic'), findsNothing);

    await tester.tap(find.byTooltip('Add topic'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Recipes ');
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, 'Recipes'), findsOneWidget);
    expect(store.topics.value.last.name, 'Recipes');

    // The new topic is selected, so it can be deleted from the app bar.
    await store.dispatch(
      SaveNote(
        Note.create(topicId: store.topics.value.last.id)
            .copyWith(title: 'Pancakes'),
      ),
    );
    await tester.tap(find.byTooltip('Delete topic'));
    await tester.pumpAndSettle();
    expect(find.text('Its note will be moved to Uncategorised.'), findsOne);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.topics.value.length, 2);

    await tester.tap(find.byTooltip('Delete topic'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Recipes'), findsNothing);
    expect(store.topics.value, [Topic.uncategorised]);

    // Now on Uncategorised, with the moved note; it can't be deleted.
    expect(find.text('Pancakes'), findsOneWidget);
    expect(find.byTooltip('Delete topic'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, '(All)'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Delete topic'), findsNothing);
  });

  testWidgets('long-press selects several topics to delete, with a prompt', (
    tester,
  ) async {
    final store = await _freshStore();
    final [a, b, c] = [
      for (final n in ['A', 'B', 'C']) Topic.create(n),
    ];
    for (final t in [a, b, c]) {
      await store.dispatch(AddTopic(t));
    }
    await store.dispatch(
      SaveNote(Note.create(topicId: a.id).copyWith(title: 'In A')),
    );
    await store.dispatch(
      SaveNote(Note.create(topicId: b.id).copyWith(title: 'In B')),
    );
    await tester.pumpWidget(NoteishApp(store: store));
    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'A'));
    await tester.pumpAndSettle();

    await tester.longPress(find.widgetWithText(ListTile, 'A'));
    await tester.pump();
    expect(find.text('1 topic selected'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(3));

    // In selection mode a tap ticks rather than switching topic.
    await tester.tap(find.widgetWithText(ListTile, 'B'));
    await tester.pump();
    expect(find.text('2 topics selected'), findsOneWidget);
    expect(find.text('In A'), findsOneWidget);

    // Uncategorised and (All) can't be ticked, or switched to, meanwhile.
    await tester.tap(find.widgetWithText(ListTile, 'Uncategorised'));
    await tester.tap(find.widgetWithText(ListTile, '(All)'));
    await tester.pump();
    expect(find.text('2 topics selected'), findsOneWidget);
    expect(find.text('In B'), findsNothing);

    await tester.tap(find.byTooltip('Delete selected topics'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 topics?'), findsOneWidget);
    expect(
      find.text('Their 2 notes will be moved to Uncategorised.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.topics.value.length, 4);
    expect(find.text('2 topics selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete selected topics'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(store.topics.value, [Topic.uncategorised, c]);
    expect(find.byType(Checkbox), findsNothing);

    // A was being shown, so the view follows its note to Uncategorised.
    expect(find.text('In A'), findsOneWidget);
    expect(find.text('In B'), findsOneWidget);
    expect(
      store.notes.value.map((n) => n.topicId),
      everyElement(Topic.uncategorisedId),
    );

    // Back leaves selection mode.
    await tester.longPress(find.widgetWithText(ListTile, 'C'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(Checkbox), findsNothing);
    expect(store.topics.value.length, 2);
  });

  test('deleting a topic moves its notes to Uncategorised', () async {
    final store = await _freshStore();
    final work = Topic.create('Work');
    await store.dispatch(AddTopic(work));
    final note = Note.create(topicId: work.id).copyWith(title: 'Report');
    await store.dispatch(SaveNote(note));
    await store.dispatch(DeleteNotes([note.id]));

    await store.dispatch(DeleteTopics([work.id]));
    expect(store.notes.value, isEmpty);

    // Restoring a note whose topic has gone puts it in Uncategorised too.
    await store.dispatch(const UndoDelete());
    expect(store.notes.value.single.topicId, Topic.uncategorisedId);

    final reloaded = LocalNoteStore(await SharedPreferences.getInstance());
    expect(reloaded.notes.value.single.topicId, Topic.uncategorisedId);
  });

  testWidgets('topics filter the notes, and new notes join the selected one', (
    tester,
  ) async {
    final store = await _freshStore();
    final work = Topic.create('Work');
    await store.dispatch(AddTopic(work));
    await store.dispatch(SaveNote(Note.create().copyWith(title: 'Loose')));
    await store.dispatch(
      SaveNote(Note.create(topicId: work.id).copyWith(title: 'Report')),
    );
    await tester.pumpWidget(NoteishApp(store: store));

    // Uncategorised is selected on open.
    expect(find.text('Loose'), findsOneWidget);
    expect(find.text('Report'), findsNothing);

    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Work'));
    await tester.pumpAndSettle();
    expect(find.text('Loose'), findsNothing);
    expect(find.text('Report'), findsOneWidget);

    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Agenda');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Agenda'), findsOneWidget);
    expect(find.text('Loose'), findsNothing); // Still on Work.
    expect(store.search('Agenda').single.topicId, work.id);

    await tester.tap(find.widgetWithText(ListTile, '(All)'));
    await tester.pumpAndSettle();
    expect(find.text('Loose'), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);
    expect(find.text('Agenda'), findsOneWidget);
  });

  testWidgets('move a note to another topic from the editor', (tester) async {
    final store = await _freshStore();
    final work = Topic.create('Work');
    await store.dispatch(AddTopic(work));
    await store.dispatch(SaveNote(Note.create().copyWith(title: 'Report')));
    await tester.pumpWidget(NoteishApp(store: store));

    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Topic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(store.notes.value.single.topicId, work.id);
    expect(find.text('Report'), findsNothing); // Still viewing Uncategorised.
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
    expect(find.byType(SnackBar), findsNothing);

    await tester.tap(find.byTooltip('Undo delete'));
    await tester.pumpAndSettle();
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.byTooltip('Undo delete'), findsNothing);
  });

  testWidgets('long-press selects several notes to delete, with undo', (
    tester,
  ) async {
    final store = await _freshStore();
    for (final title in ['One', 'Two', 'Three']) {
      await store.dispatch(SaveNote(Note.create().copyWith(title: title)));
    }
    await tester.pumpWidget(NoteishApp(store: store));
    expect(find.byType(Checkbox), findsNothing);

    await tester.longPress(find.text('One'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(3));
    expect(find.text('New note'), findsNothing);

    // In selection mode a tap ticks rather than opening the note.
    await tester.tap(find.text('Two'));
    await tester.tap(find.text('Three'));
    await tester.pump();
    await tester.tap(find.text('Three'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete selected'));
    await tester.pumpAndSettle();
    expect(store.notes.value.map((n) => n.title), ['Three']);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('New note'), findsOneWidget);

    await tester.tap(find.byTooltip('Undo delete'));
    await tester.pumpAndSettle();
    expect(store.notes.value.length, 3);
    expect(find.byTooltip('Undo delete'), findsNothing);

    // Back leaves selection mode.
    await tester.longPress(find.text('One'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(Checkbox), findsNothing);
    expect(store.notes.value.length, 3);
  });

  testWidgets('long-press and drag notes onto a topic to move them', (
    tester,
  ) async {
    final store = await _freshStore();
    final work = Topic.create('Work');
    await store.dispatch(AddTopic(work));
    for (final title in ['One', 'Two', 'Three']) {
      await store.dispatch(SaveNote(Note.create().copyWith(title: title)));
    }
    final stamps = {for (final n in store.notes.value) n.id: n.updatedAt};
    await tester.pumpWidget(NoteishApp(store: store));

    Future<void> dragOntoWork(String title) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(title)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle(); // The hidden sidebar slides open.
      await gesture.moveTo(
        tester.getCenter(find.widgetWithText(ListTile, 'Work')),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    String topicOf(String title) => store.search(title).single.topicId;

    // A single note.
    await dragOntoWork('One');
    expect(topicOf('One'), work.id);
    expect(find.text('One'), findsNothing); // Still viewing Uncategorised.
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byTooltip('Show sidebar'), findsOneWidget); // Hidden again.

    // A ticked note comes along with the dragged one.
    await tester.longPress(find.text('Two'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await dragOntoWork('Three');
    expect(topicOf('Two'), work.id);
    expect(topicOf('Three'), work.id);
    expect(find.text('No notes yet'), findsOneWidget);

    // Moving isn't an edit.
    for (final n in store.notes.value) {
      expect(n.updatedAt, stamps[n.id]);
    }
  });

  testWidgets('a phone-width screen fits two notes side by side', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await _freshStore();
    for (final title in ['One', 'Two']) {
      await store.dispatch(SaveNote(Note.create().copyWith(title: title)));
    }
    await tester.pumpWidget(NoteishApp(store: store));

    final one = tester.getRect(find.text('One'));
    final two = tester.getRect(find.text('Two'));
    expect(one.top, two.top);
    expect(one.left, isNot(two.left));
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
