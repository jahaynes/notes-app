import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noteish/note.dart';
import 'package:noteish/store/http_note_store.dart';
import 'package:noteish/store/note_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = 'user-1';
const _token = 'token-1';

/// The id of the Uncategorised topic the backend created along with [_user].
const _defaultTopic = 'topic-0';

/// A Notes API that accepts every PUT that leaves a note in its topic, holding
/// NoteViews and TopicViews. A move or DELETE goes through only if its clock has
/// seen every write to the note or topic, and a move or topic DELETE is refused
/// as the real one refuses it. Every
/// request needs [_token], which belongs to [_user] until it [expired], and
/// a note PUT must be for that user. [_user] starts with [_defaultTopic], as
/// the real backend creates it with them.
class _Backend {
  _Backend() {
    topicElsewhere(_defaultTopic, name: 'Uncategorised');
  }

  var expired = false;

  /// How many times the store was told its token was turned down.
  var rejections = 0;

  final notes = <String, Map<String, dynamic>>{};
  final topics = <String, Map<String, dynamic>>{};
  final notePuts = <Map<String, dynamic>>[];
  final noteDeletes = <String>[];
  final noteMoves = <Map<String, dynamic>>[];

  /// Each topic DELETE, whatever became of it.
  final topicDeletes = <String>[];

  /// Called with the id of a note about to be moved, to change things
  /// elsewhere first.
  void Function(String id)? beforeMove;

  /// Ids of the notes whose moves fail outright.
  final failingMoves = <String>{};

  /// Ids of the topics other users have too.
  final sharedTopics = <String>{};

  /// Stores a topic as if another device had written it.
  void topicElsewhere(String id, {required String name}) {
    topics[id] = {
      'topicId': id,
      'clock': {
        '$_user:other': (topics[id]?['clock']?['$_user:other'] ?? 0) + 1,
      },
      'name': name,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  /// Stores a note as if another device had written it.
  void putElsewhere(
    String id, {
    required String title,
    String topic = _defaultTopic,
  }) {
    notes[id] = {
      'noteId': id,
      'clock': {
        '$_user:other': (notes[id]?['clock']?['$_user:other'] ?? 0) + 1,
      },
      'title': title,
      'content': '',
      'colorIndex': 0,
      'showFull': false,
      'topicId': topic,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  late final client = MockClient((request) async {
    if (expired || request.headers['Authorization'] != 'Bearer $_token') {
      return http.Response('', 401);
    }
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
          'clock': {'${body['userId']}:${body['deviceId']}': 0},
          'name': body['name'],
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        };
        return http.Response('', 204);
      case ('PUT', ['note', final id]):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['userId'] != _user) return http.Response('', 403);
        notePuts.add(body);
        final current = notes[id];
        if (current != null && current['topicId'] != body['topicId']) {
          return _json(current, status: 409);
        }
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
      case ('POST', ['note', final id, 'move']):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        beforeMove?.call(id);
        if (failingMoves.contains(id)) return http.Response('', 500);
        noteMoves.add({'noteId': id, ...body});
        final current = notes[id];
        if (current == null) return http.Response('', 404);
        if (current['topicId'] != body['fromTopicId'] ||
            !_hasSeen(body['clock'] as Map, current)) {
          return _json(current, status: 409);
        }
        notes[id] = {
          'noteId': id,
          'clock': body['clock'],
          'title': body['title'],
          'content': body['content'],
          'colorIndex': body['colorIndex'],
          'showFull': body['showFull'],
          'topicId': body['toTopicId'],
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        };
        return http.Response('', 204);
      case ('DELETE', ['note', final id]):
        noteDeletes.add(id);
        final incoming = (jsonDecode(request.body) as Map)['clock'] as Map;
        final stored = notes[id];
        if (stored != null && !_hasSeen(incoming, stored)) {
          return _json(stored, status: 409);
        }
        notes.remove(id);
        return http.Response('', 204);
      case ('DELETE', ['topic', final id]):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        topicDeletes.add(id);
        final inTopic = [
          for (final n in notes.values)
            if (n['topicId'] == id) n,
        ];
        if (sharedTopics.contains(id) && inTopic.isNotEmpty) {
          return _json('SharedWithNotes', status: 422);
        }
        final stored = topics[id];
        if (stored != null && !_hasSeen(body['clock'] as Map, stored)) {
          return _json(stored, status: 409);
        }
        if (inTopic.isNotEmpty) return _json('HasNotes', status: 422);
        topics.remove(id);
        return http.Response('', 204);
    }
    return http.Response('', 404);
  });

  /// Whether [clock] has seen every write in the [stored] view's clock.
  static bool _hasSeen(Map clock, Map stored) => (stored['clock'] as Map)
      .entries
      .every((e) => ((clock[e.key] ?? -1) as int) >= (e.value as int));

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
    await SharedPreferences.getInstance(),
    (server: Uri.parse('http://notes.test/'), userId: _user, token: _token),
    onRejected: () => backend.rejections++,
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

  test('a turned-down token is reported', () async {
    final backend = _Backend()..putElsewhere('a', title: 'A');
    final store = await _open(backend);
    expect(backend.rejections, 0);

    backend.expired = true;
    await expectLater(
      store.refreshNote('a'),
      throwsA(
        isA<NotesApiException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    expect(backend.rejections, 1);
  });

  test('flush writes held-back edits straight away', () async {
    final backend = _Backend();
    final store = await _open(backend);
    final note = Note.create(topicId: store.defaultTopic.id)
        .copyWith(title: 'A');
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
    expect(store.topics.value.map((t) => t.id), [_defaultTopic, 'work']);
    expect(store.byId('w')?.title, 'W');
  });

  test(
    'refreshing a note fetches it, but deleted notes stay deleted',
    () async {
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
    },
  );

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

  test('moving a note goes through the move endpoint, in one write', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A');
    final store = await _open(backend);
    await store.dispatch(const MoveNotes(['a'], 'work'));

    expect(backend.notePuts, isEmpty);
    final move = backend.noteMoves.single;
    expect(move['fromTopicId'], _defaultTopic);
    expect(move['toTopicId'], 'work');
    expect(move['title'], 'A');
    expect(backend.notes['a']?['topicId'], 'work');

    // Writes after that are ordinary ones again.
    await store.dispatch(SaveNote(store.byId('a')!.copyWith(title: 'A2')));
    expect(backend.noteMoves, hasLength(1));
    expect(backend.notePuts.single['topicId'], 'work');
    expect(backend.notes['a']?['title'], 'A2');
  });

  test('a note the backend has never had is created in its topic', () async {
    final backend = _Backend()..topicElsewhere('work', name: 'Work');
    final store = await _open(backend);
    final note = Note.create(topicId: store.defaultTopic.id)
        .copyWith(title: 'A');
    final save = store.dispatch(SaveNote(note));
    await store.dispatch(MoveNotes([note.id], 'work'));
    await save;
    expect(backend.noteMoves, isEmpty);
    expect(backend.notes[note.id]?['topicId'], 'work');
  });

  test('moving a note changed elsewhere brings back the change', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A');
    final store = await _open(backend);
    backend.putElsewhere('a', title: 'changed');
    await store.dispatch(const MoveNotes(['a'], 'work'));
    expect(store.byId('a')?.title, 'changed');
    expect(store.byId('a')?.topicId, _defaultTopic);
    expect(backend.notes['a']?['topicId'], _defaultTopic);
  });

  test('moving a note deleted elsewhere does not bring it back', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A');
    final store = await _open(backend);
    backend.notes.remove('a');
    await store.dispatch(const MoveNotes(['a'], 'work'));
    expect(store.byId('a'), isNull);
    expect(backend.notes, isEmpty);
  });

  test('deleting a topic moves its notes out first', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A', topic: 'work');
    final store = await _open(backend);
    await store.dispatch(const DeleteTopics(['work']));

    expect(store.topics.value.map((t) => t.id), [_defaultTopic]);
    expect(store.byId('a')?.topicId, _defaultTopic);
    expect(backend.topics.keys, [_defaultTopic]);
    expect(backend.notes['a']?['topicId'], _defaultTopic);
    expect(backend.notePuts, isEmpty);
    expect(backend.noteMoves.single['fromTopicId'], 'work');
    expect(backend.noteMoves.single['toTopicId'], _defaultTopic);

    // The next write carries on from the clock the move left.
    final device =
        '$_user:${(await SharedPreferences.getInstance()).getString('device_v1')}';
    final ticked = {...backend.notes['a']!['clock'] as Map};
    expect(ticked[device], 1);
    await store.dispatch(SaveNote(store.byId('a')!.copyWith(title: 'A2')));
    expect(backend.notePuts.single['clock'], {...ticked, device: 2});
    await store.refreshTopic(null);
    expect(store.byId('a')?.title, 'A2');
  });

  test('deleting an empty topic moves nothing', () async {
    final backend = _Backend()..topicElsewhere('work', name: 'Work');
    final store = await _open(backend);
    await store.dispatch(const DeleteTopics(['work']));
    expect(backend.topics.keys, [_defaultTopic]);
    expect(backend.topicDeletes, ['work']);
    expect(backend.noteMoves, isEmpty);
  });

  test('deleting a topic moves notes this device has not seen', () async {
    final backend = _Backend()..topicElsewhere('work', name: 'Work');
    final store = await _open(backend);
    await store.refreshTopic(null);
    backend.putElsewhere('new', title: 'New', topic: 'work');
    await store.dispatch(const DeleteTopics(['work']));
    expect(backend.topics.keys, [_defaultTopic]);
    expect(backend.notes['new']?['topicId'], _defaultTopic);
    expect(store.byId('new')?.topicId, _defaultTopic);
  });

  test('a move that conflicts mid-delete is retried with the change', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A', topic: 'work');
    final store = await _open(backend);
    var edited = false;
    backend.beforeMove = (id) {
      if (edited) return;
      edited = true;
      backend.putElsewhere(id, title: 'changed', topic: 'work');
    };
    await store.dispatch(const DeleteTopics(['work']));

    expect(backend.topics.keys, [_defaultTopic]);
    expect(backend.notes['a']?['topicId'], _defaultTopic);
    expect(backend.notes['a']?['title'], 'changed');
    expect(store.byId('a')?.title, 'changed');
    expect(store.byId('a')?.topicId, _defaultTopic);
  });

  test('a note arriving mid-delete is moved too', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A', topic: 'work');
    final store = await _open(backend);
    backend.beforeMove = (id) {
      if (id == 'a') backend.putElsewhere('b', title: 'B', topic: 'work');
    };
    await store.dispatch(const DeleteTopics(['work']));

    expect(backend.topics.keys, [_defaultTopic]);
    expect(backend.notes['b']?['topicId'], _defaultTopic);
    expect(store.byId('b')?.topicId, _defaultTopic);
  });

  test('a note deleted elsewhere mid-delete stays deleted', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A', topic: 'work');
    final store = await _open(backend);
    backend.beforeMove = (id) => backend.notes.remove(id);
    await store.dispatch(const DeleteTopics(['work']));

    expect(backend.topics.keys, [_defaultTopic]);
    expect(backend.notes, isEmpty);
    expect(store.byId('a'), isNull);
  });

  test('a delete failing partway leaves moved notes moved', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A', topic: 'work')
      ..putElsewhere('b', title: 'B', topic: 'work');
    final store = await _open(backend);
    backend.failingMoves.add('b');
    await expectLater(
      store.dispatch(const DeleteTopics(['work'])),
      throwsA(isA<NotesApiException>()),
    );

    expect(store.topics.value.map((t) => t.id), [_defaultTopic, 'work']);
    expect(backend.topics.keys, contains('work'));
    expect(backend.notes['a']?['topicId'], _defaultTopic);
    expect(store.byId('a')?.topicId, _defaultTopic);
    expect(backend.notes['b']?['topicId'], 'work');
    expect(store.byId('b')?.topicId, 'work');

    // Trying again carries on from there.
    backend.failingMoves.clear();
    await store.dispatch(const DeleteTopics(['work']));
    expect(backend.topics.keys, [_defaultTopic]);
    expect(backend.notes['b']?['topicId'], _defaultTopic);
    expect(store.byId('b')?.topicId, _defaultTopic);
  });

  test('a topic that keeps getting notes is given up on', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('n0', title: 'N', topic: 'work');
    final store = await _open(backend);
    var next = 0;
    backend.beforeMove = (_) {
      backend.putElsewhere('n${++next}', title: 'N', topic: 'work');
    };
    await expectLater(
      store.dispatch(const DeleteTopics(['work'])),
      throwsA(isA<NotesApiException>()),
    );
    expect(store.topics.value.map((t) => t.id), [_defaultTopic, 'work']);
    expect(backend.topics.keys, contains('work'));
    // Every note is still somewhere, with this device agreeing where.
    for (final MapEntry(key: id, value: view) in backend.notes.entries) {
      final local = store.byId(id);
      if (local != null) expect(local.topicId, view['topicId']);
    }
  });

  test('a waiting edit to a note follows it out of a deleted topic', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A', topic: 'work');
    final store = await _open(backend);
    final edit = store.dispatch(
      SaveNote(store.byId('a')!.copyWith(title: 'A2')),
    );
    await store.dispatch(const DeleteTopics(['work']));
    await edit;
    expect(backend.notes['a']?['topicId'], _defaultTopic);
    expect(backend.notes['a']?['title'], 'A2');
  });

  test('a topic changed elsewhere comes back with its notes', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A', topic: 'work');
    final store = await _open(backend);
    backend.topicElsewhere('work', name: 'Renamed');
    await store.dispatch(const DeleteTopics(['work']));

    expect(store.topics.value.map((t) => t.name), ['Uncategorised', 'Renamed']);
    expect(store.byId('a')?.topicId, 'work');
    expect(backend.notes['a']?['topicId'], 'work');
    expect(backend.notePuts, isEmpty);
    expect(backend.noteMoves, isEmpty);
  });

  test(
    'a topic renamed mid-delete comes back, with notes staying moved',
    () async {
      final backend = _Backend()
        ..topicElsewhere('work', name: 'Work')
        ..putElsewhere('a', title: 'A', topic: 'work');
      final store = await _open(backend);
      backend.beforeMove = (_) =>
          backend.topicElsewhere('work', name: 'Renamed');
      await store.dispatch(const DeleteTopics(['work']));

      expect(store.topics.value.map((t) => t.name), [
        'Uncategorised',
        'Renamed',
      ]);
      expect(store.byId('a')?.topicId, _defaultTopic);
      expect(backend.notes['a']?['topicId'], _defaultTopic);
    },
  );

  test('a shared topic with notes is kept, and says why', () async {
    final backend = _Backend()
      ..topicElsewhere('work', name: 'Work')
      ..putElsewhere('a', title: 'A', topic: 'work');
    backend.sharedTopics.add('work');
    final store = await _open(backend);

    await expectLater(
      store.dispatch(const DeleteTopics(['work'])),
      throwsA(
        isA<SharedTopicsNotDeleted>().having(
          (e) => e.topics.map((t) => t.id),
          'topics',
          ['work'],
        ),
      ),
    );
    expect(store.topics.value.map((t) => t.id), [_defaultTopic, 'work']);
    expect(store.byId('a')?.topicId, 'work');
    expect(backend.topics.keys, contains('work'));
    expect(backend.noteMoves, isEmpty);
  });
}
