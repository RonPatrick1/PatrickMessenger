import 'package:flutter/foundation.dart';

class AppConfig {
  static const _productionHomeserver = 'https://patrick-lamphier.com';
  static const _productionServerName = 'matrix.patrick-lamphier.com';
  static const _productionLiamUserId = '@liam:matrix.patrick-lamphier.com';
  static const _productionPushGateway =
      'https://patrick-lamphier.com/_matrix/push/v1/notify';
  static const _iosPushAppId = 'com.patricklamphier.patrickMessenger';

  final Uri homeserver;
  final String serverName;
  final bool allowInsecureDevelopment;
  final String giphyApiKey;
  final String liamUserId;
  final String pushGatewayUrl;
  final String iosPushAppId;

  const AppConfig({
    required this.homeserver,
    required this.serverName,
    this.allowInsecureDevelopment = false,
    this.giphyApiKey = '',
    this.liamUserId = _productionLiamUserId,
    this.pushGatewayUrl = _productionPushGateway,
    this.iosPushAppId = _iosPushAppId,
  });

  factory AppConfig.fromEnvironment() {
    const configuredHomeserver = String.fromEnvironment(
      'MATRIX_HOMESERVER_URL',
      defaultValue: _productionHomeserver,
    );
    const configuredServerName = String.fromEnvironment(
      'MATRIX_SERVER_NAME',
      defaultValue: _productionServerName,
    );
    const configuredAllowInsecure = bool.fromEnvironment(
      'ALLOW_INSECURE_DEVELOPMENT',
    );
    final usePublicMobileServer =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    return AppConfig(
      homeserver: Uri.parse(
        usePublicMobileServer ? _productionHomeserver : configuredHomeserver,
      ),
      serverName: usePublicMobileServer
          ? _productionServerName
          : configuredServerName,
      allowInsecureDevelopment: usePublicMobileServer
          ? false
          : configuredAllowInsecure,
      giphyApiKey: const String.fromEnvironment('GIPHY_API_KEY'),
      liamUserId: const String.fromEnvironment(
        'LIAM_MATRIX_USER_ID',
        defaultValue: _productionLiamUserId,
      ),
      pushGatewayUrl: const String.fromEnvironment(
        'MATRIX_PUSH_GATEWAY_URL',
        defaultValue: _productionPushGateway,
      ),
      iosPushAppId: const String.fromEnvironment(
        'IOS_PUSH_APP_ID',
        defaultValue: _iosPushAppId,
      ),
    );
  }

  void validate() {
    if (!homeserver.hasScheme || homeserver.host.isEmpty) {
      throw const FormatException(
        'MATRIX_HOMESERVER_URL must be an absolute URL.',
      );
    }
    if (homeserver.scheme != 'https' && !allowInsecureDevelopment) {
      throw const FormatException(
        'The homeserver must use HTTPS. Set ALLOW_INSECURE_DEVELOPMENT=true '
        'only for a local development server.',
      );
    }
    if (homeserver.scheme != 'https' && homeserver.scheme != 'http') {
      throw const FormatException('Only HTTPS and HTTP URLs are supported.');
    }
    if (serverName.trim().isEmpty ||
        serverName.contains('/') ||
        serverName.contains('://')) {
      throw const FormatException(
        'MATRIX_SERVER_NAME must be a Matrix server name, not a URL.',
      );
    }
    if (!RegExp(r'^@[^:\s]+:[^\s]+$').hasMatch(liamUserId)) {
      throw const FormatException(
        'LIAM_MATRIX_USER_ID must be a complete Matrix user ID.',
      );
    }
    final pushGateway = Uri.tryParse(pushGatewayUrl);
    if (pushGateway == null ||
        pushGateway.scheme != 'https' ||
        pushGateway.host.isEmpty) {
      throw const FormatException(
        'MATRIX_PUSH_GATEWAY_URL must be an HTTPS URL.',
      );
    }
  }

  String matrixIdFor(String username) {
    final trimmed = username.trim();
    if (trimmed.startsWith('@')) {
      return trimmed;
    }
    return '@$trimmed:$serverName';
  }

  String get displayHomeserver {
    final defaultPort =
        (homeserver.scheme == 'https' && homeserver.port == 443) ||
        (homeserver.scheme == 'http' && homeserver.port == 80);
    return defaultPort
        ? '${homeserver.scheme}://${homeserver.host}'
        : '${homeserver.scheme}://${homeserver.host}:${homeserver.port}';
  }
}
