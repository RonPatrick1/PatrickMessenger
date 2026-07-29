import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

/// Uploads a Matrix attachment without retaining the original and encrypted
/// file as full-size byte arrays in the application's memory at the same time.
class StreamingEncryptedMediaUpload {
  static Future<String?> send({
    required Room room,
    required File source,
    required String name,
    required String mimeType,
    Event? inReplyTo,
    Map<String, dynamic>? extraContent,
  }) async {
    final length = await source.length();
    final mediaConfig = await room.client.getConfig(
      cacheLifetime: Duration.zero,
      throwOnUpdateFailure: true,
    );
    final maximum = mediaConfig.mUploadSize;
    if (maximum != null && length > maximum) {
      throw FileTooBigMatrixException(length, maximum);
    }

    final temporaryDirectory = await getTemporaryDirectory();
    final encrypted = File(
      path.join(
        temporaryDirectory.path,
        'patrick-upload-${DateTime.now().microsecondsSinceEpoch}.bin',
      ),
    );

    try {
      final encryption = await Isolate.run(
        () => _encryptFileInChunks(source.path, encrypted.path),
      );
      final contentUri = await _upload(
        client: room.client,
        encrypted: encrypted,
        name: name,
        mimeType: mimeType,
      );

      return room.sendEvent({
        'msgtype': MatrixFile.msgTypeFromMime(mimeType),
        'body': name,
        'filename': name,
        'file': {
          'url': contentUri.toString(),
          'mimetype': mimeType,
          'v': 'v2',
          'key': {
            'alg': 'A256CTR',
            'ext': true,
            'k': encryption.key,
            'key_ops': ['encrypt', 'decrypt'],
            'kty': 'oct',
          },
          'iv': encryption.iv,
          'hashes': {'sha256': encryption.sha256},
        },
        'info': {'mimetype': mimeType, 'size': length},
        ...?extraContent,
      }, inReplyTo: inReplyTo);
    } finally {
      if (await encrypted.exists()) await encrypted.delete();
    }
  }

  static Future<Uri> _upload({
    required Client client,
    required File encrypted,
    required String name,
    required String mimeType,
  }) async {
    final homeserver = client.homeserver;
    final accessToken = client.accessToken;
    if (homeserver == null || accessToken == null) {
      throw StateError('The Matrix account is not connected.');
    }

    final uploadUri = homeserver.resolveUri(
      Uri(path: '_matrix/media/v3/upload', queryParameters: {'filename': name}),
    );
    final httpClient = HttpClient();
    try {
      final request = await httpClient.postUrl(uploadUri);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
      request.headers.set(HttpHeaders.contentTypeHeader, mimeType);
      request.contentLength = await encrypted.length();
      await request.addStream(encrypted.openRead());
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Matrix upload failed with HTTP ${response.statusCode}: $body',
          uri: uploadUri,
        );
      }
      final value = jsonDecode(body);
      final contentUri = value is Map ? value['content_uri']?.toString() : null;
      if (contentUri == null || !contentUri.startsWith('mxc://')) {
        throw const FormatException('Matrix returned an invalid content URI.');
      }
      return Uri.parse(contentUri);
    } finally {
      httpClient.close(force: true);
    }
  }
}

Future<_StreamingEncryptionResult> _encryptFileInChunks(
  String sourcePath,
  String destinationPath,
) async {
  final random = Random.secure();
  final key = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  // Matrix encrypted attachments use a random 64-bit IV followed by a
  // 64-bit counter beginning at zero.
  final iv = Uint8List(16);
  for (var index = 0; index < 8; index++) {
    iv[index] = random.nextInt(256);
  }

  final cipher = SICStreamCipher(AESEngine())
    ..init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
  final digest = SHA256Digest();
  final destination = File(destinationPath).openWrite();
  try {
    await for (final inputList in File(sourcePath).openRead()) {
      final input = inputList is Uint8List
          ? inputList
          : Uint8List.fromList(inputList);
      final output = Uint8List(input.length);
      cipher.processBytes(input, 0, input.length, output, 0);
      digest.update(output, 0, output.length);
      destination.add(output);
    }
  } finally {
    await destination.close();
  }

  final hash = Uint8List(digest.digestSize);
  digest.doFinal(hash, 0);
  return _StreamingEncryptionResult(
    key: base64Url.encode(key).replaceAll('=', ''),
    iv: base64.encode(iv).replaceAll('=', ''),
    sha256: base64.encode(hash).replaceAll('=', ''),
  );
}

class _StreamingEncryptionResult {
  final String key;
  final String iv;
  final String sha256;

  const _StreamingEncryptionResult({
    required this.key,
    required this.iv,
    required this.sha256,
  });
}
