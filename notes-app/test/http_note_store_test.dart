import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noteish/note.dart';
import 'package:noteish/store/http_note_store.dart';
import 'package:noteish/store/note_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = 'user-1';

/// A Notes API that accepts every PUT, holding NoteViews and TopicViews. A
/// DELETE goes through only if its clock has seen every write to the note.
class _Backend {
  final notes = <String, Map<String, dynamic>>{};
  final topics = <String, Map<String, dynamic>>{};
  final notePuts = <Map<String, dynamic>>[];
  final noteDeletes = <String>[];

  /// Stores a note as if another device had written it.
  void putElsewhere(String id, {required String title, String topic = _user}) {
    notes[id] = {
      'noteId': id,
      'clock': {'$_user:other': (notes[id]?['clock']?['$_user:other'] ?? 0) + 1},
      'title': title,
      'content': '',
      'colorIndex': 0,
      'showFull': false,
      'topicId': topic,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  late final client = MockClient((request) async {
    final path = request.url.pathSegments;
    switch ((request.method, path)) {
      case ('GET', ['user', _, 'topics']):
        return _json(topics.values.toList());
      case ('GET', ['topic', final id, 'notes']):
        return _json([
          for (final n in notes.values)
            if (n['topicId'] == id) n,
        ]);
      case ('GET', ['note', final id]):
        final note = notes[id];
        return note == null ? http.Response('', 404) : _json(note);
      case ('PUT', ['topic', final id]):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        topics[id] = {
          'topicId': id,
          'clock': <String, int>{},
          'name': body['name'],
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        };
        return http.Response('', 204);
      case ('PUT', ['note', final id]):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        notePuts.add(body);
        notes[id] = {
          'noteId': id,
          'clock': body['clock'],
          'title': body['title'],
          'content': body['content'],
          'colorIndex': body['colorIndex'],
          'showFull': body['showFull'],
          'topicId': body['topicId'],
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        };
        return http.Response('', 204);
      case ('DELETE', ['note', final id]):
        noteDeletes.add(id);
        final incoming = (jsonDecode(request.body) as Map)['clock'] as Map;
        final stored = notes[id];
        if (stored != null &&
            (stored['clock'] as Map).entries.any(
              (e) => ((incoming[e.key] ?? -1) as int) < (e.value as int),
            )) {
          return _json(stored, status: 409);
        }
        notes.remove(id);
        return http.Response('', 204);
    }
    return http.Response('', 404);
  });

  static http.Response _json(Object body, {int status = 200}) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
}

Future<HttpNoteStore> _open(_Backend backend) async {
  SharedPreferences.setMockInitialValues({});
  return HttpNoteStore.open(
    backend.client,
    Uri.parse('http://notes.test/'),
    await SharedPreferences.getInstance(),
    userId: _user,
  );
}

void main() {
  test('a burst of edits is written once, as its last version', () async {
    final backend = _Backend();
    final store = await _open(backend);
    var note = Note.create(topicId: store.defaultTopic.id);
    final saves = <Future<void>>[];
    for (final c in 'hello'.split('')) {
      note = note.copyWith(title: note.title + c);
      saves.add(store.dispatch(SaveNote(note)));
    }
    expect(store.byId(note.id)?.title, 'hello');
    await Future.wait(saves);

    expect(backend.notePuts, hasLength(1));
    expect(backend.notePuts.single['title'], 'hello');
    final device = (await SharedPreferences.getInstance()).getString(
      'device_v1',
    );
    expect(backend.notePuts.single['clock'], {'$_user:$device': 1});
  });

  test('flush writes held-back edits straight away', () async {
    final backend = _Backend();
    final store = await _open(backend);
    final note = Note.create(
      topicId: store.defaultTopic.id,
    ).copyWith(title: 'A');
    store.dispatch(SaveNote(note));
    await store.flush();
    expect(backend.notes[note.id]?['title'], 'A');
  });

  test('refreshing a topic picks up changes made elsewhere', () async {
    final backend = _Backend();
    backend.topics['work'] = {
      'topicId': 'work',
      'clock': <String, int>{},
      'name': 'Work',
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    backend
      ..putElsewhere('changed', title: 'old')
      ..putElsewhere('moved', title: 'moved')
      ..putElsewhere('edited here', title: 'old');
    final store = await _open(backend);
    await store.dispatch(
      SaveNote(store.byId('edited here')!.copyWith(title: 'mine')),
    );
    store.dispatch(
      SaveNote(store.byId('edited here')!.copyWith(title: 'mine, unsent')),
    );

    backend
      ..putElsewhere('changed', title: 'new')
      ..putElsewhere('moved', title: 'moved', topic: 'work')
      ..putElsewhere('added', title: 'added')
      ..putElsewhere('edited here', title: 'theirs');
    await store.refreshTopic(store.defaultTopic.id);

    expect(store.byId('changed')?.title, 'new');
    expect(store.byId('added')?.title, 'added');
    expect(store.byId('moved'), isNull);
    expect(store.byId('edited here')?.title, 'mine, unsent');

    await store.refreshTopic('work');
    expect(store.byId('moved')?.topicId, 'work');
    await store.flush();
  });

  test('refreshing everything picks up new topics', () async {
    final backend = _Backend();
    final store = await _open(backend);
    backend.topics['work'] = {
      'topicId': 'work',
      'clock': <String, int>{},
      'name': 'Work',
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    backend.putElsewhere('w', title: 'W', topic: 'work');
    await store.refreshTopic(null);
    expect(store.topics.value.map((t) => t.id), [_user, 'work']);
    expect(store.byId('w')?.title, 'W');
  });

  test('refreshing a note fetches it, but deleted notes stay deleted', () async {
    final backend = _Backend();
    backend
      ..putElsewhere('a', title: 'old')
      ..putElsewhere('b', title: 'B');
    final store = await _open(backend);
    backend.putElsewhere('a', title: 'new');
    await store.refreshNote('a');
    expect(store.byId('a')?.title, 'new');

    store.dispatch(const DeleteNotes(['b']));
    await store.refreshTopic(store.defaultTopic.id);
    expect(store.byId('b'), isNull, reason: 'waiting to be deleted');

    await store.refreshNote('never written');
    expect(store.byId('never written'), isNull);
    await store.flush();
  });

  test('deleting a note deletes it from the backend', () async {
    final backend = _Backend()..putElsewhere('a', title: 'A');
    final store = await _open(backend);
    await store.dispatch(const DeleteNotes(['a']));
    expect(backend.notes, isEmpty);
    await store.refreshTopic(null);
    expect(store.byId('a'), isNull);

    await store.dispatch(const UndoDelete());
    expect(backend.notes['a']?['title'], 'A');
  });

  test('a quick undo means the delete is never sent', () async {
    final backend = _Backend()..putElsewhere('a', title: 'A');
    final store = await _open(backend);
    final delete = store.dispatch(const DeleteNotes(['a']));
    await store.dispatch(const UndoDelete());
    await delete;
    expect(backend.noteDeletes, isEmpty);
    expect(backend.notes['a']?['title'], 'A');
  });

  test('saving a note empty deletes it from the backend', () async {
    final backend = _Backend()..putElsewhere('a', title: 'A');
    final store = await _open(backend);
    await store.dispatch(SaveNote(store.byId('a')!.copyWith(title: '')));
    expect(store.byId('a'), isNull);
    expect(backend.notes, isEmpty);
  });

  test('deleting a note changed elsewhere brings back the change', () async {
    final backend = _Backend()..putElsewhere('a', title: 'A');
    final store = await _open(backend);
    backend.putElsewhere('a', title: 'changed');
    await store.dispatch(const DeleteNotes(['a']));
    expect(store.byId('a')?.title, 'changed');
    expect(store.lastDeleted.value, isEmpty);
    expect(backend.notes['a']?['title'], 'changed');
  });
}
