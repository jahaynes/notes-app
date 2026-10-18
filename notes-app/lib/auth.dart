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

/// The Notes API base URL logged in to, who's logged in there, and the
/// bearer token for their requests.
typedef Login = ({Uri server, String userId, String token});

/// Where the notes are kept, as picked at the login screen.
sealed class Storage {
  const Storage();

  /// The same for two [Storage]s that hold the same notes.
  Object get id;
}

/// Kept on this device only, with nobody logged in.
final class OnDevice extends Storage {
  const OnDevice();

  @override
  Object get id => #onDevice;
}

/// Kept on the backend [login] is for, as the user it's for.
final class OnServer extends Storage {
  const OnServer(this.login);

  final Login login;

  @override
  Object get id => (login.server, login.userId);
}

/// POST /login turned down the username and password.
class WrongCredentials implements Exception {
  @override
  String toString() => 'WrongCredentials';
}

/// Logging in to and out of a Notes API backend, whichever one the user
/// picks, or keeping notes on this device instead. The token and the
/// backend it's for are kept in SharedPreferences, so a login lasts until it
/// expires or is logged out of, as does picking this device. [account] is
/// the user logged in, or null when there's none.
class AuthSession {
  AuthSession(this._client, this._prefs)
    : _onDevice = ValueNotifier(_prefs.getBool(_onDeviceKey) ?? false);

  final http.Client _client;
  final SharedPreferences _prefs;

  static const _tokenKey = 'auth_token_v1';
  static const _serverKey = 'auth_server_v1';
  static const _triedServerKey = 'auth_tried_server_v1';
  static const _onDeviceKey = 'auth_on_device_v1';

  ValueListenable<Account?> get account => _account;
  final _account = ValueNotifier<Account?>(null);

  final ValueNotifier<bool> _onDevice;

  /// Notified whenever [storage] may have changed.
  Listenable get changes => Listenable.merge([_account, _onDevice]);

  /// Where the notes are kept, or null until it's picked at the login
  /// screen.
  Storage? get storage => _onDevice.value
      ? const OnDevice()
      : switch (login) {
          final login? => OnServer(login),
          null => null,
        };

  /// The bearer token for requests, or null when logged out.
  String? get token => _prefs.getString(_tokenKey);

  /// The base URL of the backend logged in to, or null when logged out.
  Uri? get server => switch (_prefs.getString(_serverKey)) {
    final String url => Uri.parse(url),
    null => null,
  };

  /// The base URL of the backend last tried logging in to, whether or not
  /// that worked, kept after logging out so it can be offered again.
  Uri? get triedServer => switch (_prefs.getString(_triedServerKey)) {
    final String url => Uri.parse(url),
    null => null,
  };

  /// The logged-in user and their token, or null when logged out or the
  /// saved login couldn't be checked.
  Login? get login => switch ((server, _account.value, token)) {
    (final Uri server, Account(:final id), final String token) => (
      server: server,
      userId: id,
      token: token,
    ),
    _ => null,
  };

  /// Picks up a saved login, dropping it if the backend no longer accepts
  /// it, e.g. it has expired or the backend was restarted with a new key.
  Future<void> restore() async {
    final saved = token;
    if (saved == null) return;
    final savedServer = server;
    // Saved before the backend was picked at login, so its backend is
    // unknown.
    if (savedServer == null) return logOut();
    try {
      _account.value = await _me(savedServer, saved);
    } on WrongCredentials {
      await logOut();
    } on Exception catch (e) {
      // Offline, perhaps: keep the token for next time.
      debugPrint('Could not restore login: $e');
    }
  }

  /// Logs in to the backend at [server]. Throws [WrongCredentials] if it
  /// turns them down.
  Future<void> logIn(Uri server, String username, String password) async {
    await _prefs.setString(_triedServerKey, server.toString());
    final response = await _client.post(
      server.resolve('login'),
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
    final account = await _me(server, token);
    await _prefs.setString(_serverKey, server.toString());
    await _prefs.setString(_tokenKey, token);
    _account.value = account;
  }

  /// Keeps notes on this device, with nobody logged in, until [logOut].
  Future<void> useDevice() async {
    await logOut();
    await _prefs.setBool(_onDeviceKey, true);
    _onDevice.value = true;
  }

  /// Logs out if [token] is still the one in use, as the backend has turned
  /// it down, e.g. it has expired. A token from an earlier login is
  /// ignored, as requests made with it can still be finishing.
  Future<void> rejected(String token) async {
    if (this.token == token) await logOut();
  }

  /// Logs out of the backend, or stops using this device's notes, going
  /// back to the login screen. The device's notes stay on it.
  Future<void> logOut() async {
    await _prefs.remove(_tokenKey);
    await _prefs.remove(_serverKey);
    await _prefs.remove(_onDeviceKey);
    _account.value = null;
    _onDevice.value = false;
  }

  /// Throws [WrongCredentials] if [server] doesn't accept [token], or its
  /// user is gone.
  Future<Account> _me(Uri server, String token) async {
    final response = await _client.get(
      server.resolve('me'),
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
