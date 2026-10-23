import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteish/appearance.dart';
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
  return LocalNoteStore.open(await SharedPreferences.getInstance());
}

void main() {
  test('store persists, and drops empty notes', () async {
    final store = await _freshStore();
    final a = Note.create(topicId: store.defaultTopic.id).copyWith(title: 'A');
    final b = Note.create(topicId: store.defaultTopic.id).copyWith(title: 'B');
    await store.dispatch(SaveNote(a));
    await store.dispatch(SaveNote(b));
    await store.dispatch(
      SaveNote(Note.create(topicId: store.defaultTopic.id)),
    ); // empty, ignored

    expect(store.notes.value.map((n) => n.title), ['B', 'A']);
    expect(store.search('a').single.title, 'A');

    // Reload from the same prefs.
    final reloaded = await LocalNoteStore.open(
      await SharedPreferences.getInstance(),
    );
    expect(reloaded.notes.value.length, 2);
  });

  test('topics persist, and the default topic is undeletable', () async {
    final store = await _freshStore();
    expect(store.topics.value, [store.defaultTopic]);

    final work = Topic.create('Work');
    final home = Topic.create('Home');
    await store.dispatch(AddTopic(work));
    await store.dispatch(AddTopic(home));
    await store.dispatch(DeleteTopics([work.id]));
    await store.dispatch(DeleteTopics([store.defaultTopic.id])); // ignored

    expect(store.topics.value, [store.defaultTopic, home]);

    final reloaded = await LocalNoteStore.open(
      await SharedPreferences.getInstance(),
    );
    expect(reloaded.topics.value, [store.defaultTopic, home]);
  });

  test('the user and their default topic are created once', () async {
    final store = await _freshStore();
    expect(store.defaultTopic.name, 'Uncategorised');
    expect(store.defaultTopic.id, isNot('uncategorised'));

    final reloaded = await LocalNoteStore.open(
      await SharedPreferences.getInstance(),
    );
    expect(reloaded.user, store.user);
  });

  test('notes saved before the user existed join the default topic', () async {
    SharedPreferences.setMockInitialValues({
      'notes_v1': jsonEncode([
        {'id': 'a', 'title': 'Pseudo-topic', 'topicId': 'uncategorised'},
        {'id': 'b', 'title': 'No topic'},
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final store = await LocalNoteStore.open(prefs);
    expect(
      store.notes.value.map((n) => n.topicId),
      everyElement(store.defaultTopic.id),
    );
    expect(prefs.getString('notes_v1'), isNot(contains('"uncategorised"')));
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
    expect(store.topics.value, [store.defaultTopic]);

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
    expect(store.topics.value, [store.defaultTopic, c]);
    expect(find.byType(Checkbox), findsNothing);

    // A was being shown, so the view follows its note to Uncategorised.
    expect(find.text('In A'), findsOneWidget);
    expect(find.text('In B'), findsOneWidget);
    expect(
      store.notes.value.map((n) => n.topicId),
      everyElement(store.defaultTopic.id),
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
    expect(store.notes.value.single.topicId, store.defaultTopic.id);

    final reloaded = await LocalNoteStore.open(
      await SharedPreferences.getInstance(),
    );
    expect(reloaded.notes.value.single.topicId, store.defaultTopic.id);
  });

  testWidgets('topics filter the notes, and new notes join the selected one', (
    tester,
  ) async {
    final store = await _freshStore();
    final work = Topic.create('Work');
    await store.dispatch(AddTopic(work));
    await store.dispatch(
      SaveNote(
        Note.create(topicId: store.defaultTopic.id).copyWith(title: 'Loose'),
      ),
    );
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
    await store.dispatch(
      SaveNote(
        Note.create(topicId: store.defaultTopic.id).copyWith(title: 'Report'),
      ),
    );
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
      await store.dispatch(
        SaveNote(
          Note.create(topicId: store.defaultTopic.id).copyWith(title: title),
        ),
      );
    }
    await tester.pumpWidget(NoteishApp(store: store));
    expect(find.byType(Checkbox), findsNothing);

    await tester.longPress(find.text('One'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(Card), matching: find.byType(Checkbox)),
      findsNWidgets(3),
    );
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
      await store.dispatch(
        SaveNote(
          Note.create(topicId: store.defaultTopic.id).copyWith(title: title),
        ),
      );
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
      await store.dispatch(
        SaveNote(
          Note.create(topicId: store.defaultTopic.id).copyWith(title: title),
        ),
      );
    }
    await tester.pumpWidget(NoteishApp(store: store));

    final one = tester.getRect(find.text('One'));
    final two = tester.getRect(find.text('Two'));
    expect(one.top, two.top);
    expect(one.left, isNot(two.left));
  });

  testWidgets('opening a note cancels ticked topics', (tester) async {
    final store = await _freshStore();
    await store.dispatch(AddTopic(Topic.create('Work')));
    await store.dispatch(
      SaveNote(
        Note.create(topicId: store.defaultTopic.id).copyWith(title: 'Loose'),
      ),
    );
    await tester.pumpWidget(NoteishApp(store: store));
    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    await tester.longPress(find.widgetWithText(ListTile, 'Work'));
    await tester.pump();
    expect(find.text('1 topic selected'), findsOneWidget);

    await tester.tap(find.text('Loose'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('1 topic selected'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('the hidden sidebar takes no keyboard focus', (tester) async {
    final store = await _freshStore();
    await tester.pumpWidget(NoteishApp(store: store));

    String? focusedTooltip() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<Tooltip>()
        ?.message;
    final reached = <String?>[];
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      reached.add(focusedTooltip());
    }
    expect(reached, isNot(contains('Add topic')));

    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    reached.clear();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      reached.add(focusedTooltip());
    }
    expect(reached, contains('Add topic'));
  });

  testWidgets('back closes search rather than the app', (tester) async {
    final store = await _freshStore();
    await store.dispatch(
      SaveNote(
        Note.create(topicId: store.defaultTopic.id).copyWith(title: 'One'),
      ),
    );
    await store.dispatch(
      SaveNote(
        Note.create(topicId: store.defaultTopic.id).copyWith(title: 'Two'),
      ),
    );
    await tester.pumpWidget(NoteishApp(store: store));
    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'one');
    await tester.pump();
    expect(find.text('Two'), findsNothing);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Two'), findsOneWidget);
  });

  testWidgets('show in full removes truncation on the overview', (
    tester,
  ) async {
    final store = await _freshStore();
    final body = List.generate(20, (i) => 'line $i').join('\n');
    store.dispatch(
      SaveNote(
        Note.create(topicId: store.defaultTopic.id).copyWith(body: body),
      ),
    );
    await tester.pumpWidget(NoteishApp(store: store));

    expect(tester.widget<Text>(find.text(body)).maxLines, 8);

    expect(find.text('Show in full'), findsNothing);
    await tester.longPress(find.text(body));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show in full'));
    await tester.pump();

    expect(store.notes.value.single.showFull, isTrue);
    expect(tester.widget<Text>(find.text(body)).maxLines, isNull);

    final reloaded = await LocalNoteStore.open(
      await SharedPreferences.getInstance(),
    );
    expect(reloaded.notes.value.single.showFull, isTrue);
  });

  testWidgets('color applies to every ticked note and not the others', (
    tester,
  ) async {
    final store = await _freshStore();
    for (final title in ['One', 'Two', 'Three']) {
      await store.dispatch(
        SaveNote(
          Note.create(topicId: store.defaultTopic.id).copyWith(title: title),
        ),
      );
    }
    await tester.pumpWidget(NoteishApp(store: store));
    expect(find.byTooltip('Color'), findsNothing);

    await tester.longPress(find.text('One'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Two'));
    await tester.pump();
    await tester.tap(find.byTooltip('Color'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(InkResponse),
          )
          .at(2),
    );
    await tester.pumpAndSettle();

    Note titled(String t) => store.notes.value.firstWhere((n) => n.title == t);
    expect(titled('One').colorIndex, 2);
    expect(titled('Two').colorIndex, 2);
    expect(titled('Three').colorIndex, 0);
  });

  testWidgets('tab indents bullets in the note body instead of moving focus', (
    tester,
  ) async {
    final store = await _freshStore();
    await tester.pumpWidget(NoteishApp(store: store));

    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    final body = find.byType(TextField).last;
    await tester.tap(body);
    await tester.enterText(body, '• milk');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(store.notes.value.single.body, '    • milk');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(store.notes.value.single.body, '• milk');

    final editable = tester.widget<EditableText>(
      find.descendant(of: body, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
  });

  testWidgets('arrow keys and backspace treat a bullet indent as a unit', (
    tester,
  ) async {
    final store = await _freshStore();
    await tester.pumpWidget(NoteishApp(store: store));

    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    final body = find.byType(TextField).last;
    await tester.tap(body);
    await tester.enterText(body, 'a\n    • milk');
    final controller = tester.widget<TextField>(body).controller!;
    controller.selection = const TextSelection.collapsed(offset: 8);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(controller.selection.baseOffset, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(controller.selection.baseOffset, 8);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(store.notes.value.single.body, 'a\n• milk');
  });

  testWidgets('undo puts back the body as it was, without making bullets', (
    tester,
  ) async {
    final store = await _freshStore();
    await tester.pumpWidget(NoteishApp(store: store));

    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    final body = find.byType(TextField).last;
    await tester.tap(body);
    await tester.enterText(body, '• milk');
    // Past the undo history's throttling, so each edit gets its own entry.
    await tester.pump(const Duration(seconds: 1));
    // Enter then backspace leaves a newline after a bullet...
    await tester.enterText(body, '• milk\n');
    await tester.enterText(body, '• milk\n•');
    expect(store.notes.value.single.body, '• milk\n');
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(body, '• milk');
    await tester.pump(const Duration(seconds: 1));

    // ...comes back as it was, not as if Enter were typed again.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    expect(store.notes.value.single.body, '• milk\n');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    expect(store.notes.value.single.body, '• milk');
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

  testWidgets('a theme picked in the sidebar is shown and kept', (
    tester,
  ) async {
    final store = await _freshStore();
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      AppearanceScope(
        appearance: Appearance(prefs),
        child: NoteishApp(store: store),
      ),
    );
    Color primary() =>
        Theme.of(tester.element(find.byType(Scaffold).first))
            .colorScheme
            .primary;
    final honey = primary();

    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Honey'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Theme'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Ocean'));
    await tester.pumpAndSettle();

    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.widgetWithText(ListTile, 'Ocean'), findsOneWidget);
    expect(primary(), isNot(honey));
    expect(Appearance(prefs).value, Palette.ocean);
  });

  test('an unknown saved theme falls back to the default', () async {
    SharedPreferences.setMockInitialValues({'appearance_palette_v1': 'gone'});
    final appearance = Appearance(await SharedPreferences.getInstance());
    expect(appearance.value, Palette.fallback);
  });

  test('neon themes are dark even in light mode', () {
    for (final palette in Palette.values) {
      expect(
        palette.theme(Brightness.light).brightness,
        palette.alwaysDark ? Brightness.dark : Brightness.light,
        reason: palette.label,
      );
    }
    expect(
      Palette.grid.theme(Brightness.light).colorScheme.primary,
      Palette.grid.seed,
    );
  });
}
