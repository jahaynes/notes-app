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

/// A Notes API knowing one user, john/something, whose token is 'good'.
final _client = MockClient((request) async {
  switch ((request.method, request.url.path)) {
    case ('POST', '/login'):
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
    case ('GET', '/me'):
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
  final auth = AuthSession(_client, Uri.parse('http://api/'), prefs);
  await auth.restore();
  return auth;
}

void main() {
  test('a saved login is restored, or dropped if refused', () async {
    final good = await _session({'auth_token_v1': 'good'});
    expect(good.account.value?.username, 'john');

    final stale = await _session({'auth_token_v1': 'expired'});
    expect(stale.account.value, isNull);
    expect(stale.token, isNull);
  });

  testWidgets('notes open as whoever logs in, and logging out leaves them', (
    tester,
  ) async {
    final auth = await _session({});
    final prefs = await SharedPreferences.getInstance();
    final opened = <Login>[];
    await tester.pumpWidget(
      LoggedInApp(
        auth: auth,
        openStore: (login) {
          opened.add(login);
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
    expect(opened, [(userId: 'u-1', token: 'good')]);
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
}
