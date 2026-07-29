import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/services/streaming_encrypted_video_playback.dart';
import 'package:pointycastle/export.dart';

void main() {
  test(
    'serves a suffix seek with a decrypted homeserver range request',
    () async {
      final plaintext = Uint8List.fromList(
        List<int>.generate(3 * 1024 * 1024, (index) => index % 251),
      );
      final key = Uint8List.fromList(
        List<int>.generate(32, (index) => index + 1),
      );
      final iv = Uint8List.fromList(
        List<int>.generate(16, (index) => index + 41),
      );
      final cipher = SICStreamCipher(AESEngine())
        ..init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
      final ciphertext = Uint8List(plaintext.length);
      cipher.processBytes(plaintext, 0, plaintext.length, ciphertext, 0);
      final digest = SHA256Digest();
      digest.update(ciphertext, 0, ciphertext.length);
      final hash = Uint8List(digest.digestSize);
      digest.doFinal(hash, 0);

      final releaseFullDownload = Completer<void>();
      final fullDownloadServed = Completer<void>();
      final requestedRanges = <String>[];
      final sourceServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      sourceServer.listen((request) async {
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        if (rangeHeader == null) {
          await releaseFullDownload.future;
          request.response
            ..headers.contentLength = ciphertext.length
            ..add(ciphertext);
          await request.response.close();
          fullDownloadServed.complete();
          return;
        }

        requestedRanges.add(rangeHeader);
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(rangeHeader)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${ciphertext.length}',
          )
          ..headers.contentLength = end - start + 1
          ..add(Uint8List.sublistView(ciphertext, start, end + 1));
        await request.response.close();
      });

      EncryptedVideoStreamSession? session;
      final localClient = HttpClient();
      try {
        session = await EncryptedVideoStreamSession.start(
          downloadUri: Uri.parse(
            'http://${sourceServer.address.address}:${sourceServer.port}/video',
          ),
          accessToken: 'test-token',
          key: key,
          iv: iv,
          totalLength: ciphertext.length,
          expectedSha256: base64.encode(hash),
          mimeType: 'video/mp4',
        );

        const suffixLength = 257;
        final request = await localClient.getUrl(
          Uri.parse('http://127.0.0.1:${session.port}/video'),
        );
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=-$suffixLength');
        final response = await request.close();
        final body = await response.fold<List<int>>(
          <int>[],
          (bytes, chunk) => bytes..addAll(chunk),
        );

        expect(response.statusCode, HttpStatus.partialContent);
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes ${plaintext.length - suffixLength}-${plaintext.length - 1}/'
          '${plaintext.length}',
        );
        expect(body, plaintext.sublist(plaintext.length - suffixLength));
        final alignedStart =
            (plaintext.length - suffixLength) -
            ((plaintext.length - suffixLength) % 16);
        expect(
          requestedRanges,
          contains('bytes=$alignedStart-${plaintext.length - 1}'),
        );

        releaseFullDownload.complete();
        await fullDownloadServed.future;
      } finally {
        if (!releaseFullDownload.isCompleted) releaseFullDownload.complete();
        session?.dispose();
        localClient.close(force: true);
        await sourceServer.close(force: true);
      }
    },
  );
}
