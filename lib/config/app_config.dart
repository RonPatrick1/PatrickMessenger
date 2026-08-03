class AppConfig {
  static const _productionHomeserver = 'https://patrick-lamphier.com';
  static const _productionServerName = 'matrix.patrick-lamphier.com';
  static const _productionLiamUserId = '@liam:matrix.patrick-lamphier.com';
  static const _productionSearchUserId = '@search:matrix.patrick-lamphier.com';
  static const _productionGiphyApiKey = 'AZ4NP1gCNzC2rktp957hMNWbzR3A6Iko';
  static const _productionPushGateway =
      'https://patrick-lamphier.com/_matrix/push/v1/notify';
  static const _iosPushAppId = 'com.patricklamphier.patrickMessenger';
  static const _androidPushAppId =
      'com.patricklamphier.patrickMessenger.android';

  final Uri homeserver;
  final String serverName;
  final bool allowInsecureDevelopment;
  final String giphyApiKey;
  final String liamUserId;
  final String searchUserId;
  final String pushGatewayUrl;
  final String iosPushAppId;
  final String androidPushAppId;
  final String androidFirebaseApiKey;
  final String androidFirebaseAppId;
  final String androidFirebaseMessagingSenderId;
  final String androidFirebaseProjectId;

  const AppConfig({
    required this.homeserver,
    required this.serverName,
    this.allowInsecureDevelopment = false,
    this.giphyApiKey = _productionGiphyApiKey,
    this.liamUserId = _productionLiamUserId,
    this.searchUserId = _productionSearchUserId,
    this.pushGatewayUrl = _productionPushGateway,
    this.iosPushAppId = _iosPushAppId,
    this.androidPushAppId = _androidPushAppId,
    this.androidFirebaseApiKey = '',
    this.androidFirebaseAppId = '',
    this.androidFirebaseMessagingSenderId = '',
    this.androidFirebaseProjectId = '',
  });

  factory AppConfig.fromEnvironment() => AppConfig(
    homeserver: Uri.parse(_productionHomeserver),
    serverName: _productionServerName,
    allowInsecureDevelopment: false,
    giphyApiKey: const String.fromEnvironment(
      'GIPHY_API_KEY',
      defaultValue: _productionGiphyApiKey,
    ),
    liamUserId: const String.fromEnvironment(
      'LIAM_MATRIX_USER_ID',
      defaultValue: _productionLiamUserId,
    ),
    searchUserId: const String.fromEnvironment(
      'SEARCH_MATRIX_USER_ID',
      defaultValue: _productionSearchUserId,
    ),
    pushGatewayUrl: const String.fromEnvironment(
      'MATRIX_PUSH_GATEWAY_URL',
      defaultValue: _productionPushGateway,
    ),
    iosPushAppId: const String.fromEnvironment(
      'IOS_PUSH_APP_ID',
      defaultValue: _iosPushAppId,
    ),
    androidPushAppId: const String.fromEnvironment(
      'ANDROID_PUSH_APP_ID',
      defaultValue: _androidPushAppId,
    ),
    androidFirebaseApiKey: const String.fromEnvironment(
      'ANDROID_FIREBASE_API_KEY',
    ),
    androidFirebaseAppId: const String.fromEnvironment(
      'ANDROID_FIREBASE_APP_ID',
    ),
    androidFirebaseMessagingSenderId: const String.fromEnvironment(
      'ANDROID_FIREBASE_MESSAGING_SENDER_ID',
    ),
    androidFirebaseProjectId: const String.fromEnvironment(
      'ANDROID_FIREBASE_PROJECT_ID',
    ),
  );

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
    if (!RegExp(r'^@[^:\s]+:[^\s]+$').hasMatch(searchUserId)) {
      throw const FormatException(
        'SEARCH_MATRIX_USER_ID must be a complete Matrix user ID.',
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
    final androidFirebaseValues = <String>[
      androidFirebaseApiKey,
      androidFirebaseAppId,
      androidFirebaseMessagingSenderId,
      androidFirebaseProjectId,
    ];
    final configuredAndroidFirebaseValues = androidFirebaseValues
        .where((value) => value.trim().isNotEmpty)
        .length;
    if (configuredAndroidFirebaseValues != 0 &&
        configuredAndroidFirebaseValues != androidFirebaseValues.length) {
      throw const FormatException(
        'All ANDROID_FIREBASE_* values must be supplied together.',
      );
    }
  }

  bool get hasAndroidFirebaseConfig =>
      androidFirebaseApiKey.trim().isNotEmpty &&
      androidFirebaseAppId.trim().isNotEmpty &&
      androidFirebaseMessagingSenderId.trim().isNotEmpty &&
      androidFirebaseProjectId.trim().isNotEmpty;

  String matrixIdFor(String username) {
    final trimmed = username.trim();
    if (trimmed.startsWith('@')) {
      return trimmed;
    }
    return '@$trimmed:$serverName';
  }
}
