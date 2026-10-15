import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Who's logged in to the Notes API, as GET /me reports them.
@immutable
class Account {
  const Account({required this.id, required this.username});

  final String id;
  final String username;

  factory Account.fromView(Map<String, dynamic> json) => Account(
    id: json['userId'] as String,
    username: json['username'] as String,
  );
}

/// Who's logged in, and the bearer token for their requests.
typedef Login = ({String userId, String token});

/// POST /login turned down the username and password.
class WrongCredentials implements Exception {
  @override
  String toString() => 'WrongCredentials';
}

/// Logging in to and out of the Notes API at [_baseUri]. The token is kept
/// in SharedPreferences, so a login lasts until it expires or is logged out
/// of. [account] is the user it belongs to, or null when logged out.
class AuthSession {
  AuthSession(this._client, this._baseUri, this._prefs);

  final http.Client _client;
  final Uri _baseUri;
  final SharedPreferences _prefs;

  static const _tokenKey = 'auth_token_v1';

  ValueListenable<Account?> get account => _account;
  final _account = ValueNotifier<Account?>(null);

  /// The bearer token for requests, or null when logged out.
  String? get token => _prefs.getString(_tokenKey);

  /// The logged-in user and their token, or null when logged out or the
  /// saved login couldn't be checked.
  Login? get login => switch ((_account.value, token)) {
    (Account(:final id), final String token) => (userId: id, token: token),
    _ => null,
  };

  /// Picks up a saved login, dropping it if the backend no longer accepts
  /// it, e.g. it has expired or the backend was restarted with a new key.
  Future<void> restore() async {
    final saved = token;
    if (saved == null) return;
    try {
      _account.value = await _me(saved);
    } on WrongCredentials {
      await logOut();
    } on Exception catch (e) {
      // Offline, perhaps: keep the token for next time.
      debugPrint('Could not restore login: $e');
    }
  }

  /// Throws [WrongCredentials] if the backend turns them down.
  Future<void> logIn(String username, String password) async {
    final response = await _client.post(
      _baseUri.resolve('login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (response.statusCode == 401) throw WrongCredentials();
    if (response.statusCode != 200) {
      throw http.ClientException(
        'POST login -> ${response.statusCode} ${response.body}',
      );
    }
    final token =
        (jsonDecode(response.body) as Map<String, dynamic>)['access_token']
            as String;
    final account = await _me(token);
    await _prefs.setString(_tokenKey, token);
    _account.value = account;
  }

  /// Logs out if [token] is still the one in use, as the backend has turned
  /// it down, e.g. it has expired. A token from an earlier login is
  /// ignored, as requests made with it can still be finishing.
  Future<void> rejected(String token) async {
    if (this.token == token) await logOut();
  }

  Future<void> logOut() async {
    await _prefs.remove(_tokenKey);
    _account.value = null;
  }

  /// Throws [WrongCredentials] if [token] isn't accepted, or its user is
  /// gone.
  Future<Account> _me(String token) async {
    final response = await _client.get(
      _baseUri.resolve('me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 401 || response.statusCode == 404) {
      throw WrongCredentials();
    }
    if (response.statusCode != 200) {
      throw http.ClientException(
        'GET me -> ${response.statusCode} ${response.body}',
      );
    }
    return Account.fromView(jsonDecode(response.body) as Map<String, dynamic>);
  }
}
