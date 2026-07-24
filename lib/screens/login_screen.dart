import 'dart:io';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../config/app_config.dart';
import '../settings/theme_preference.dart';

class LoginScreen extends StatefulWidget {
  final Client client;
  final AppConfig config;
  final ThemePreferenceController themeController;

  const LoginScreen({
    required this.client,
    required this.config,
    required this.themeController,
    super.key,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _submitting = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);
    try {
      await widget.client.checkHomeserver(
        widget.config.homeserver,
        checkWellKnown: false,
        fetchAuthMetadata: false,
      );
      await widget.client.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(
          user: _usernameController.text.trim(),
        ),
        password: _passwordController.text,
        initialDeviceDisplayName: _deviceDisplayName(),
      );
      _passwordController.clear();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sign-in failed. Check the server, username, and password.',
          ),
        ),
      );
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colorScheme.primaryContainer,
                                  shape: BoxShape.circle,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(15),
                                  child: Icon(
                                    Icons.lock_outline,
                                    color: colorScheme.onPrimaryContainer,
                                    size: 30,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 22),
                            Text(
                              'Patrick Messenger',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Private messaging on a server you trust.',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            const SizedBox(height: 24),
                            _ServerStatus(url: widget.config.displayHomeserver),
                            const SizedBox(height: 24),
                            TextFormField(
                              controller: _usernameController,
                              enabled: !_submitting,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              autofillHints: const [AutofillHints.username],
                              decoration: const InputDecoration(
                                labelText: 'Username',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? 'Enter your username.'
                                  : null,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _passwordController,
                              enabled: !_submitting,
                              obscureText: _obscurePassword,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: const [AutofillHints.password],
                              onFieldSubmitted: (_) => _signIn(),
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(Icons.password_outlined),
                                suffixIcon: IconButton(
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                  tooltip: _obscurePassword
                                      ? 'Show password'
                                      : 'Hide password',
                                ),
                              ),
                              validator: (value) =>
                                  value == null || value.isEmpty
                                  ? 'Enter your password.'
                                  : null,
                            ),
                            const SizedBox(height: 20),
                            FilledButton.icon(
                              onPressed: _submitting ? null : _signIn,
                              icon: _submitting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.login),
                              label: Text(
                                _submitting ? 'Connecting…' : 'Sign in',
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              'Development milestone — encryption is enabled, '
                              'but this client has not received a security audit.',
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: ThemePreferenceMenuButton(
                  controller: widget.themeController,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerStatus extends StatelessWidget {
  final String url;

  const _ServerStatus({required this.url});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.dns_outlined,
            size: 20,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              url,
              style: TextStyle(color: colors.onSecondaryContainer),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

String _deviceDisplayName() {
  if (Platform.isIOS) return 'Patrick Messenger on iPhone or iPad';
  if (Platform.isAndroid) return 'Patrick Messenger on Android';
  if (Platform.isMacOS) return 'Patrick Messenger on macOS';
  if (Platform.isLinux) return 'Patrick Messenger on Ubuntu';
  return 'Patrick Messenger';
}
