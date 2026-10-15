import 'package:flutter/material.dart';

import 'auth.dart';

/// Asks for a username and password and logs in with them, showing an
/// error if that fails. Whatever shows this moves on once [auth] has an
/// account.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});

  final AuthSession auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _complete =>
      _username.text.trim().isNotEmpty && _password.text.isNotEmpty;

  Future<void> _submit() async {
    if (!_complete || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.logIn(_username.text.trim(), _password.text);
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
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _complete && !_busy ? _submit : null,
                  child: const Text('Log in'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
