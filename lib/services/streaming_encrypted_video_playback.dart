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
const _sequentialWaitAllowance = 2 * 1024 * 1024;

/// Serves encrypted Matrix video to a local media player without putting the
/// complete attachment in memory.
///
/// A sequential background download is written to an encrypted temporary
/// file and hashed for Matrix integrity verification. Requests close to the
/// downloaded prefix are served from that cache as it grows. Seeks beyond the
/// prefix (including the MP4 metadata that is often stored at the end) are
/// fetched from the homeserver with an HTTP range request and decrypted while
/// being forwarded to the player.
class EncryptedVideoStreamSession {
  final Isolate _isolate;
  final ReceivePort _receivePort;
  final Directory _cacheDirectory;
  final int port;

  /// Emits `integrity-failure` if the complete ciphertext does not match the
  /// attachment's Matrix SHA-256 hash.
  final Stream<String> events;

  bool _disposed = false;

  EncryptedVideoStreamSession._(
    this._isolate,
    this._receivePort,
    this._cacheDirectory,
    this.port,
    this.events,
  );

  static Future<EncryptedVideoStreamSession> start({
    required Uri downloadUri,
    required String accessToken,
    required Uint8List key,
    required Uint8List iv,
    required int totalLength,
    required String? expectedSha256,
    required String mimeType,
  }) async {
    if (totalLength <= 0) {
      throw ArgumentError.value(totalLength, 'totalLength');
    }
    final cacheDirectory = await Directory.systemTemp.createTemp(
      'patrick-video-',
    );
    final receivePort = ReceivePort();
    final broadcast = receivePort.asBroadcastStream();
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
        cachePath: '${cacheDirectory.path}/ciphertext.bin',
        replyPort: receivePort.sendPort,
      ),
    );
    final first = await broadcast.first;
    if (first is! int) {
      isolate.kill(priority: Isolate.immediate);
      receivePort.close();
      await cacheDirectory.delete(recursive: true);
      throw StateError('Failed to start video stream server: $first');
    }
    return EncryptedVideoStreamSession._(
      isolate,
      receivePort,
      cacheDirectory,
      first,
      broadcast.where((event) => event is String).cast<String>(),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isolate.kill(priority: Isolate.immediate);
    _receivePort.close();
    unawaited(_deleteCache());
  }

  Future<void> _deleteCache() async {
    // Give native file handles from the killed isolate a moment to close.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      if (await _cacheDirectory.exists()) {
        await _cacheDirectory.delete(recursive: true);
      }
    } catch (_) {
      // The OS also clears its temporary directory. A delayed native handle
      // release should not turn stopping playback into a user-visible error.
    }
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
  final String cachePath;
  final SendPort replyPort;

  const _StreamSessionParams({
    required this.downloadUri,
    required this.accessToken,
    required this.key,
    required this.iv,
    required this.totalLength,
    required this.expectedSha256,
    required this.mimeType,
    required this.cachePath,
    required this.replyPort,
  });
}

Future<void> _isolateMain(_StreamSessionParams params) async {
  final replyPort = params.replyPort;
  try {
    final httpClient = http.Client();
    final coordinator = _FetchCoordinator(
      totalLength: params.totalLength,
      cacheFile: File(params.cachePath),
    );
    final downloadUri = Uri.parse(params.downloadUri);
    final verificationRequest = http.Request('GET', downloadUri)
      ..headers[HttpHeaders.authorizationHeader] =
          'Bearer ${params.accessToken}';
    unawaited(
      coordinator
          .consume(
            httpClient.send(verificationRequest),
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
          httpClient: httpClient,
          downloadUri: downloadUri,
          accessToken: params.accessToken,
          key: params.key,
          iv: params.iv,
          totalLength: params.totalLength,
          mimeType: params.mimeType,
        ),
      );
    });
  } catch (error) {
    replyPort.send('start-failed: $error');
  }
}

Future<void> _handleRequest(
  HttpRequest request, {
  required _FetchCoordinator coordinator,
  required http.Client httpClient,
  required Uri downloadUri,
  required String accessToken,
  required Uint8List key,
  required Uint8List iv,
  required int totalLength,
  required String mimeType,
}) async {
  final response = request.response;
  try {
    final range = _parseRange(
      request.headers.value(HttpHeaders.rangeHeader),
      totalLength,
    );
    if (range == null) {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalLength');
      await response.close();
      return;
    }

    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, mimeType)
      ..contentLength = range.length;
    if (range.partial) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end}/$totalLength',
      );
    } else {
      response.statusCode = HttpStatus.ok;
    }

    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    final closeEnoughToCache =
        coordinator.finished ||
        range.start <= coordinator.bytesReceived + _sequentialWaitAllowance;
    if (closeEnoughToCache) {
      await _serveFromGrowingCache(
        response,
        range: range,
        coordinator: coordinator,
        key: key,
        iv: iv,
      );
    } else {
      await _serveRemoteRange(
        response,
        range: range,
        httpClient: httpClient,
        downloadUri: downloadUri,
        accessToken: accessToken,
        key: key,
        iv: iv,
      );
    }
    await response.close();
  } catch (_) {
    // Players routinely abandon one range request when seeking to another.
    // Closing only that response lets the local stream server remain usable.
    try {
      await response.close();
    } catch (_) {}
  }
}

Future<void> _serveFromGrowingCache(
  HttpResponse response, {
  required _ByteRange range,
  required _FetchCoordinator coordinator,
  required Uint8List key,
  required Uint8List iv,
}) async {
  var cursor = range.start;
  while (cursor <= range.end) {
    final chunkEnd = min(cursor + _rangeWindowSize - 1, range.end);
    final alignedStart = cursor - (cursor % 16);
    final ciphertext = await coordinator.read(alignedStart, chunkEnd);
    response.add(
      decryptRange(
        ciphertext: ciphertext,
        ciphertextOffset: alignedStart,
        start: cursor,
        end: chunkEnd,
        key: key,
        iv: iv,
      ),
    );
    cursor = chunkEnd + 1;
  }
}

Future<void> _serveRemoteRange(
  HttpResponse response, {
  required _ByteRange range,
  required http.Client httpClient,
  required Uri downloadUri,
  required String accessToken,
  required Uint8List key,
  required Uint8List iv,
}) async {
  final alignedStart = range.start - (range.start % 16);
  final remoteRequest = http.Request('GET', downloadUri)
    ..headers[HttpHeaders.authorizationHeader] = 'Bearer $accessToken'
    ..headers[HttpHeaders.rangeHeader] = 'bytes=$alignedStart-${range.end}';
  final remoteResponse = await httpClient.send(remoteRequest);
  if (remoteResponse.statusCode != HttpStatus.partialContent) {
    throw HttpException(
      'Homeserver did not honor encrypted video range request '
      '(HTTP ${remoteResponse.statusCode}).',
      uri: downloadUri,
    );
  }

  final counter = counterForAesCtrOffset(iv, alignedStart);
  final cipher = SICStreamCipher(AESEngine())
    ..init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), counter));
  var skip = range.start - alignedStart;
  var remaining = range.length;
  await for (final list in remoteResponse.stream) {
    if (remaining == 0) break;
    final input = list is Uint8List ? list : Uint8List.fromList(list);
    final output = Uint8List(input.length);
    cipher.processBytes(input, 0, input.length, output, 0);
    if (skip >= output.length) {
      skip -= output.length;
      continue;
    }
    final available = output.length - skip;
    final count = min(available, remaining);
    response.add(Uint8List.sublistView(output, skip, skip + count));
    remaining -= count;
    skip = 0;
  }
  if (remaining != 0) {
    throw StateError('Encrypted video range ended $remaining bytes early.');
  }
}

_ByteRange? _parseRange(String? header, int totalLength) {
  if (header == null) {
    return _ByteRange(start: 0, end: totalLength - 1, partial: false);
  }
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null) return null;
  final startText = match.group(1)!;
  final endText = match.group(2)!;
  if (startText.isEmpty && endText.isEmpty) return null;

  late int start;
  late int end;
  if (startText.isEmpty) {
    final suffixLength = int.tryParse(endText);
    if (suffixLength == null || suffixLength <= 0) return null;
    start = max(0, totalLength - suffixLength);
    end = totalLength - 1;
  } else {
    final parsedStart = int.tryParse(startText);
    if (parsedStart == null || parsedStart < 0 || parsedStart >= totalLength) {
      return null;
    }
    start = parsedStart;
    if (endText.isEmpty) {
      end = totalLength - 1;
    } else {
      final parsedEnd = int.tryParse(endText);
      if (parsedEnd == null || parsedEnd < start) return null;
      end = min(parsedEnd, totalLength - 1);
    }
  }
  return _ByteRange(start: start, end: end, partial: true);
}

class _ByteRange {
  final int start;
  final int end;
  final bool partial;

  const _ByteRange({
    required this.start,
    required this.end,
    required this.partial,
  });

  int get length => end - start + 1;
}

class _FetchCoordinator {
  final int totalLength;
  final File cacheFile;
  int bytesReceived = 0;
  bool failed = false;
  Object? error;
  bool finished = false;

  final List<_RangeWaiter> _waiters = [];

  _FetchCoordinator({required this.totalLength, required this.cacheFile});

  Future<void> consume(
    Future<http.StreamedResponse> responseFuture, {
    required String? expectedSha256,
  }) async {
    final digest = SHA256Digest();
    RandomAccessFile? writer;
    try {
      final response = await responseFuture;
      if (response.statusCode >= 400) {
        throw HttpException(
          'Attachment download failed with HTTP ${response.statusCode}',
        );
      }
      writer = await cacheFile.open(mode: FileMode.write);
      await for (final chunk in response.stream) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        if (bytesReceived + bytes.length > totalLength) {
          throw StateError('Attachment stream exceeded its declared size.');
        }
        await writer.writeFrom(bytes);
        digest.update(bytes, 0, bytes.length);
        bytesReceived += bytes.length;
        _completeReadyWaiters();
      }
      if (bytesReceived != totalLength) {
        throw StateError(
          'Attachment stream ended at $bytesReceived of $totalLength bytes.',
        );
      }
      if (expectedSha256 != null) {
        final hash = Uint8List(digest.digestSize);
        digest.doFinal(hash, 0);
        if (base64.normalize(base64.encode(hash)) !=
            base64.normalize(expectedSha256)) {
          throw StateError('Attachment integrity check failed.');
        }
      }
    } catch (caught) {
      failed = true;
      error = caught;
    } finally {
      await writer?.close();
      finished = true;
      _completeReadyWaiters();
    }
  }

  Future<Uint8List> read(int start, int end) async {
    await _waitFor(end + 1);
    final reader = await cacheFile.open(mode: FileMode.read);
    try {
      await reader.setPosition(start);
      final bytes = await reader.read(end - start + 1);
      if (bytes.length != end - start + 1) {
        throw StateError('Encrypted video cache returned a short read.');
      }
      return bytes;
    } finally {
      await reader.close();
    }
  }

  Future<void> _waitFor(int targetByteExclusive) {
    if (targetByteExclusive <= bytesReceived) return Future.value();
    if (finished || failed) {
      return Future.error(
        error ??
            StateError('stream ended before byte $targetByteExclusive arrived'),
      );
    }
    final waiter = _RangeWaiter(targetByteExclusive);
    _waiters.add(waiter);
    return waiter.completer.future;
  }

  void _completeReadyWaiters() {
    for (final waiter in _waiters.toList()) {
      if (waiter.target <= bytesReceived) {
        waiter.completer.complete();
        _waiters.remove(waiter);
      } else if (finished || failed) {
        waiter.completer.completeError(
          error ?? StateError('Encrypted video download ended early.'),
        );
        _waiters.remove(waiter);
      }
    }
  }
}

class _RangeWaiter {
  final int target;
  final Completer<void> completer = Completer<void>();

  _RangeWaiter(this.target);
}
