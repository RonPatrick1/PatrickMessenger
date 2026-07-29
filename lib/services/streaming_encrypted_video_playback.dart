import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import 'offset_aes_ctr.dart';

const _rangeWindowSize = 512 * 1024;

/// Serves a Matrix encrypted video attachment to a local media player over
/// a `127.0.0.1`-only HTTP server, decrypting only the byte ranges the
/// player actually requests as they arrive, instead of downloading and
/// decrypting the whole file up front. Runs its fetch/decrypt/serve loop in
/// a background isolate, since AES-CTR here is pure-Dart software crypto and
/// large-range decrypts (or the final integrity hash) shouldn't compete with
/// the UI thread.
class EncryptedVideoStreamSession {
  final Isolate _isolate;
  final int port;

  /// Emits `'integrity-failure'` if the fully-downloaded ciphertext doesn't
  /// match the attachment's recorded SHA-256 hash.
  final Stream<String> events;

  EncryptedVideoStreamSession._(this._isolate, this.port, this.events);

  static Future<EncryptedVideoStreamSession> start({
    required Uri downloadUri,
    required String accessToken,
    required Uint8List key,
    required Uint8List iv,
    required int totalLength,
    required String? expectedSha256,
    required String mimeType,
  }) async {
    final mainReceivePort = ReceivePort();
    final broadcast = mainReceivePort.asBroadcastStream();
    final isolate = await Isolate.spawn(
      _isolateMain,
      _StreamSessionParams(
        downloadUri: downloadUri.toString(),
        accessToken: accessToken,
        key: key,
        iv: iv,
        totalLength: totalLength,
        expectedSha256: expectedSha256,
        mimeType: mimeType,
        replyPort: mainReceivePort.sendPort,
      ),
    );
    final first = await broadcast.first;
    if (first is! int) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError('Failed to start video stream server: $first');
    }
    return EncryptedVideoStreamSession._(
      isolate,
      first,
      broadcast.where((event) => event is String).cast<String>(),
    );
  }

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _StreamSessionParams {
  final String downloadUri;
  final String accessToken;
  final Uint8List key;
  final Uint8List iv;
  final int totalLength;
  final String? expectedSha256;
  final String mimeType;
  final SendPort replyPort;

  const _StreamSessionParams({
    required this.downloadUri,
    required this.accessToken,
    required this.key,
    required this.iv,
    required this.totalLength,
    required this.expectedSha256,
    required this.mimeType,
    required this.replyPort,
  });
}

Future<void> _isolateMain(_StreamSessionParams params) async {
  final replyPort = params.replyPort;
  try {
    final coordinator = _FetchCoordinator(totalLength: params.totalLength);
    final httpClient = http.Client();
    final request = http.Request('GET', Uri.parse(params.downloadUri))
      ..headers['authorization'] = 'Bearer ${params.accessToken}';
    unawaited(
      coordinator
          .consume(
            httpClient.send(request),
            expectedSha256: params.expectedSha256,
          )
          .then((_) {
            if (coordinator.failed) replyPort.send('integrity-failure');
          }),
    );

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    replyPort.send(server.port);

    server.listen((request) {
      unawaited(
        _handleRequest(
          request,
          coordinator: coordinator,
          key: params.key,
          iv: params.iv,
          totalLength: params.totalLength,
          mimeType: params.mimeType,
        ),
      );
    });
  } catch (e) {
    replyPort.send('start-failed: $e');
  }
}

Future<void> _handleRequest(
  HttpRequest request, {
  required _FetchCoordinator coordinator,
  required Uint8List key,
  required Uint8List iv,
  required int totalLength,
  required String mimeType,
}) async {
  final response = request.response;
  try {
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = totalLength - 1;
    var partial = false;
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring(6).split('-');
      final startText = spec.isNotEmpty ? spec[0] : '';
      final endText = spec.length > 1 ? spec[1] : '';
      if (startText.isNotEmpty) start = int.parse(startText);
      if (endText.isNotEmpty) end = int.parse(endText);
      partial = true;
    }
    if (start < 0 || start >= totalLength || end < start) {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalLength');
      await response.close();
      return;
    }
    end = min(end, totalLength - 1);

    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, mimeType)
      ..contentLength = end - start + 1;
    if (partial) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$totalLength',
      );
    } else {
      response.statusCode = HttpStatus.ok;
    }

    var cursor = start;
    while (cursor <= end) {
      if (coordinator.failed) break;
      final chunkEnd = min(cursor + _rangeWindowSize - 1, end);
      await coordinator.waitFor(chunkEnd + 1);
      if (coordinator.failed) break;
      response.add(
        decryptRange(
          ciphertext: coordinator.buffer,
          start: cursor,
          end: chunkEnd,
          key: key,
          iv: iv,
        ),
      );
      cursor = chunkEnd + 1;
    }
    await response.close();
  } catch (_) {
    // Either the coordinator failed (propagated as an exception from
    // waitFor) or the client disconnected mid-write, e.g. mpv aborting a
    // read to seek elsewhere. Neither is fatal to the server itself.
    try {
      await response.close();
    } catch (_) {}
  }
}

class _FetchCoordinator {
  final Uint8List buffer;
  int bytesReceived = 0;
  bool failed = false;
  Object? error;

  bool _finished = false;
  final _progress = StreamController<int>.broadcast();

  _FetchCoordinator({required int totalLength}) : buffer = Uint8List(totalLength);

  Future<void> consume(
    Future<http.StreamedResponse> responseFuture, {
    required String? expectedSha256,
  }) async {
    final digest = SHA256Digest();
    try {
      final response = await responseFuture;
      if (response.statusCode >= 400) {
        throw HttpException(
          'Attachment download failed with HTTP ${response.statusCode}',
        );
      }
      await for (final chunk in response.stream) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        if (bytesReceived + bytes.length > buffer.length) {
          throw StateError('Attachment stream exceeded its declared size.');
        }
        buffer.setRange(bytesReceived, bytesReceived + bytes.length, bytes);
        digest.update(bytes, 0, bytes.length);
        bytesReceived += bytes.length;
        _progress.add(bytesReceived);
      }
      if (expectedSha256 != null) {
        final hash = Uint8List(digest.digestSize);
        digest.doFinal(hash, 0);
        if (base64.normalize(base64.encode(hash)) !=
            base64.normalize(expectedSha256)) {
          failed = true;
          error = StateError('Attachment integrity check failed.');
        }
      }
    } catch (e) {
      failed = true;
      error = e;
    } finally {
      _finished = true;
      if (failed) {
        _progress.addError(error!);
      }
      await _progress.close();
    }
  }

  Future<void> waitFor(int targetByteExclusive) async {
    if (targetByteExclusive <= bytesReceived) return;
    if (_finished) {
      throw error ??
          StateError('stream ended before byte $targetByteExclusive arrived');
    }
    await for (final received in _progress.stream) {
      if (received >= targetByteExclusive) return;
    }
    if (targetByteExclusive <= bytesReceived) return;
    throw error ??
        StateError('stream ended before byte $targetByteExclusive arrived');
  }
}
