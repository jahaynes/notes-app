import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noteish/auth.dart';
import 'package:noteish/main.dart';
import 'package:noteish/notes_screen.dart';
import 'package:noteish/store/local_note_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Notes API knowing one user, john/something, whose token is 'good',
/// under whatever base URL.
final _client = MockClient((request) async {
  switch ((request.method, request.url.pathSegments.last)) {
    case ('POST', 'login'):
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['username'] != 'john' || body['password'] != 'something') {
        return http.Response('', 401);
      }
      return http.Response(
        jsonEncode({
          'access_token': 'good',
          'token_type': 'Bearer',
          'expires_in': 86400,
        }),
        200,
      );
    case ('GET', 'me'):
      if (request.headers['Authorization'] != 'Bearer good') {
        return http.Response('', 401);
      }
      return http.Response(
        jsonEncode({
          'userId': 'u-1',
          'username': 'john',
          'createdAt': '2026-10-14T00:00:00Z',
        }),
        200,
      );
  }
  return http.Response('', 404);
});

Future<AuthSession> _session(Map<String, Object> saved) async {
  SharedPreferences.setMockInitialValues(saved);
  final prefs = await SharedPreferences.getInstance();
  final auth = AuthSession(_client, prefs);
  await auth.restore();
  return auth;
}

void main() {
  test('a saved login is restored, or dropped if refused', () async {
    final good = await _session({
      'auth_token_v1': 'good',
      'auth_server_v1': 'http://api/',
    });
    expect(good.account.value?.username, 'john');
    expect(good.login?.server, Uri.parse('http://api/'));

    final stale = await _session({
      'auth_token_v1': 'expired',
      'auth_server_v1': 'http://api/',
    });
    expect(stale.account.value, isNull);
    expect(stale.token, isNull);
    expect(stale.server, isNull);
  });

  test(
    'the last server tried is remembered, even if logging in failed',
    () async {
      final auth = await _session({});
      expect(auth.triedServer, isNull);
      await expectLater(
        auth.logIn(Uri.parse('http://elsewhere/'), 'john', 'wrong'),
        throwsA(isA<WrongCredentials>()),
      );
      expect(auth.triedServer, Uri.parse('http://elsewhere/'));
      expect(auth.server, isNull);
    },
  );

  test('a saved token for no known backend is dropped', () async {
    final auth = await _session({'auth_token_v1': 'good'});
    expect(auth.account.value, isNull);
    expect(auth.token, isNull);
  });

  test('a turned-down token logs out, unless it is an old one', () async {
    final auth = await _session({
      'auth_token_v1': 'good',
      'auth_server_v1': 'http://api/',
    });
    await auth.rejected('older');
    expect(auth.account.value?.username, 'john');

    await auth.rejected('good');
    expect(auth.account.value, isNull);
    expect(auth.token, isNull);
  });

  testWidgets('notes open as whoever logs in, and logging out leaves them', (
    tester,
  ) async {
    final auth = await _session({});
    final prefs = await SharedPreferences.getInstance();
    final opened = <Storage>[];
    await tester.pumpWidget(
      LoggedInApp(
        auth: auth,
        openStore: (storage) {
          opened.add(storage);
          return LocalNoteStore.open(prefs);
        },
      ),
    );
    expect(find.byType(NotesScreen), findsNothing);

    await tester.enterText(find.byType(TextField).at(0), 'john');
    await tester.enterText(find.byType(TextField).at(1), 'wrong');
    await tester.pump(); // Enables the button.
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();
    expect(
      find.text('Wrong username or password', findRichText: true),
      findsOneWidget,
    );
    expect(auth.account.value, isNull);
    expect(opened, isEmpty);

    await tester.enterText(find.byType(TextField).at(1), 'something');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();
    expect(opened, [
      isA<OnServer>().having((s) => s.login, 'login', (
        server: Uri.parse('http://127.0.0.1:8081/'),
        userId: 'u-1',
        token: 'good',
      )),
    ]);
    expect(find.byType(NotesScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'john'), findsOneWidget);
    await tester.tap(find.byTooltip('Log out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();
    expect(find.byType(NotesScreen), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
    expect(auth.token, isNull);
  });

  testWidgets('the server address starts local, and is kept once tried', (
    tester,
  ) async {
    final auth = await _session({});
    final prefs = await SharedPreferences.getInstance();
    final opened = <Storage>[];
    await tester.pumpWidget(
      LoggedInApp(
        auth: auth,
        openStore: (storage) {
          opened.add(storage);
          return LocalNoteStore.open(prefs);
        },
      ),
    );
    Finder address(String text) => find.widgetWithText(TextField, text);

    await tester.enterText(find.byType(TextField).at(0), 'john');
    await tester.enterText(find.byType(TextField).at(1), 'something');
    expect(address('127.0.0.1:8081'), findsNothing);
    await tester.tap(find.text('Server settings'));
    await tester.pumpAndSettle();
    expect(address('127.0.0.1:8081'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(2), '');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Log in'))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField).at(2), 'not a url');
    await tester.pump();
    expect(find.text('Not a web address'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).at(2),
      'notes.example.com/api',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();
    expect(
      (opened.single as OnServer).login.server,
      Uri.parse('https://notes.example.com/api/'),
    );

    await auth.logOut();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Server settings'));
    await tester.pumpAndSettle();
    expect(address('notes.example.com/api'), findsOneWidget);
  });

  testWidgets('notes can be kept on the device instead, until logging in', (
    tester,
  ) async {
    final auth = await _session({});
    final prefs = await SharedPreferences.getInstance();
    final opened = <Storage>[];
    await tester.pumpWidget(
      LoggedInApp(
        auth: auth,
        openStore: (storage) {
          opened.add(storage);
          return LocalNoteStore.open(prefs);
        },
      ),
    );

    await tester.tap(find.text('Server settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(
      find.widgetWithText(FilledButton, 'Use notes on this device'),
    );
    await tester.pumpAndSettle();
    expect(opened, [isA<OnDevice>()]);
    expect(find.byType(NotesScreen), findsOneWidget);

    // Picked again on the next start, with nothing to log in to.
    final next = AuthSession(_client, prefs);
    await next.restore();
    expect(next.storage, isA<OnDevice>());

    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'On this device'), findsOneWidget);
    await tester.tap(find.byTooltip('Log in to a server'));
    await tester.pumpAndSettle();
    expect(find.byType(NotesScreen), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
    expect(auth.storage, isNull);
  });
}
