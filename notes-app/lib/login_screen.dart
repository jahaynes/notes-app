import 'package:flutter/material.dart';

import 'auth.dart';

/// The backend run alongside the app, as by the notes-app-backend defaults,
/// offered when no other has been tried.
const _localServer = '127.0.0.1:8081';

/// Where the login screen keeps the notes.
enum _Where { server, local }

/// Whether [host] is this machine, where the backend is served over plain
/// http.
bool _isLoopback(String host) =>
    host == 'localhost' || host == '::1' || host.startsWith('127.');

/// [text] as a backend base URL, or null if it isn't one. Without a scheme
/// it's http for this machine and https anywhere else, and it ends in a
/// slash so paths resolve beneath it.
Uri? _parseServer(String text) {
  final trimmed = text.trim();
  // Uri.tryParse would take spaces, percent-encoding them into the host.
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;
  var uri = Uri.tryParse(trimmed.contains('://') ? trimmed : '//$trimmed');
  if (uri == null || uri.host.isEmpty) return null;
  if (!uri.hasScheme) {
    uri = uri.replace(scheme: _isLoopback(uri.host) ? 'http' : 'https');
  }
  if (!(uri.isScheme('http') || uri.isScheme('https'))) return null;
  return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
}

/// [server] as it would be typed: without the scheme or trailing slash
/// [_parseServer] would put back.
String _showServer(Uri server) {
  final bare = server.toString().replaceFirst('${server.scheme}://', '');
  final shown = bare.endsWith('/') ? bare.substring(0, bare.length - 1) : bare;
  return _parseServer(shown) == server ? shown : server.toString();
}

/// Asks for a username and password and logs in with them, showing an
/// error if that fails. Whatever shows this moves on once [auth] has an
/// account.
///
/// Tucked away under the password behind 'Server settings' are the
/// backend's address, which starts as whichever was last tried or the local
/// one if none has been, and a way to keep the notes on this device instead,
/// with no login.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});

  final AuthSession auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final _serverAddress = TextEditingController(
    text: switch (widget.auth.triedServer) {
      final Uri tried => _showServer(tried),
      null => _localServer,
    },
  );
  var _where = _Where.server;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _serverAddress.dispose();
    super.dispose();
  }

  /// The backend to log in to, or null if its address isn't one.
  Uri? get _server => _parseServer(_serverAddress.text);

  bool get _complete => switch (_where) {
    _Where.local => true,
    _Where.server =>
      _username.text.trim().isNotEmpty &&
          _password.text.isNotEmpty &&
          _server != null,
  };

  Future<void> _submit() async {
    if (!_complete || _busy) return;
    final server = _server;
    if (_where == _Where.local) {
      setState(() => _busy = true);
      await widget.auth.useDevice();
      return;
    }
    if (server == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.logIn(server, _username.text.trim(), _password.text);
    } on WrongCredentials {
      if (mounted) setState(() => _error = 'Wrong username or password');
    } on Exception catch (e) {
      debugPrint('Login failed: $e');
      if (mounted) setState(() => _error = "Couldn't reach the server");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Log in',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                if (_where == _Where.server) ...[
                  TextField(
                    controller: _username,
                    autofocus: true,
                    enabled: !_busy,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(labelText: 'Username'),
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: 'Password',
                      errorText: _error,
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 8),
                ],
                _serverPicker(context),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _complete && !_busy ? _submit : null,
                  child: Text(switch (_where) {
                    _Where.server => 'Log in',
                    _Where.local => 'Use notes on this device',
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// Which backend to log in to, or this device, collapsed to a quiet
  /// 'Server settings' that says nothing of which until it's opened.
  Widget _serverPicker(BuildContext context) {
    final address = _serverAddress.text.trim();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      shape: const Border(),
      collapsedShape: const Border(),
      textColor: muted,
      collapsedTextColor: muted,
      iconColor: muted,
      collapsedIconColor: muted,
      title: Text(
        'Server settings',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      children: [
        SegmentedButton<_Where>(
          segments: const [
            ButtonSegment(
              value: _Where.server,
              icon: Icon(Icons.dns_outlined),
              label: Text('Server'),
            ),
            ButtonSegment(
              value: _Where.local,
              icon: Icon(Icons.smartphone),
              label: Text('Local'),
            ),
          ],
          selected: {_where},
          onSelectionChanged: _busy
              ? null
              : (picked) => setState(() {
                  _where = picked.single;
                  _error = null;
                }),
        ),
        if (_where == _Where.local)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Notes are kept on this device only, with no login.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          TextField(
            controller: _serverAddress,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Server address',
              errorText: address.isNotEmpty && _server == null
                  ? 'Not a web address'
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
      ],
    );
  }
}
