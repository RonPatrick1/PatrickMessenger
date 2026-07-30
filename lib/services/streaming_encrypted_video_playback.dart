import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import 'offset_aes_ctr.dart';

/// Serves Matrix encrypted video to a local media player through a seekable
/// loopback HTTP endpoint. Every player seek becomes a homeserver byte-range
/// request and is decrypted while it is forwarded, so playback does not wait
/// for a second complete-file integrity download or retain the video in RAM.
class EncryptedVideoStreamSession {
  final Isolate _isolate;
  final ReceivePort _receivePort;
  final int port;
  final Stream<String> events;

  bool _disposed = false;

  EncryptedVideoStreamSession._(
    this._isolate,
    this._receivePort,
    this.port,
    this.events,
  );

  static Future<EncryptedVideoStreamSession> start({
    required Uri downloadUri,
    required String accessToken,
    required Uint8List key,
    required Uint8List iv,
    required int totalLength,
    required String mimeType,
  }) async {
    if (totalLength <= 0) {
      throw ArgumentError.value(totalLength, 'totalLength');
    }
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
        mimeType: mimeType,
        replyPort: receivePort.sendPort,
      ),
    );
    final first = await broadcast.first;
    if (first is! int) {
      isolate.kill(priority: Isolate.immediate);
      receivePort.close();
      throw StateError('Failed to start video stream server: $first');
    }
    return EncryptedVideoStreamSession._(
      isolate,
      receivePort,
      first,
      broadcast.where((event) => event is String).cast<String>(),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isolate.kill(priority: Isolate.immediate);
    _receivePort.close();
  }
}

class _StreamSessionParams {
  final String downloadUri;
  final String accessToken;
  final Uint8List key;
  final Uint8List iv;
  final int totalLength;
  final String mimeType;
  final SendPort replyPort;

  const _StreamSessionParams({
    required this.downloadUri,
    required this.accessToken,
    required this.key,
    required this.iv,
    required this.totalLength,
    required this.mimeType,
    required this.replyPort,
  });
}

Future<void> _isolateMain(_StreamSessionParams params) async {
  final replyPort = params.replyPort;
  try {
    final httpClient = http.Client();
    final downloadUri = Uri.parse(params.downloadUri);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    replyPort.send(server.port);
    server.listen((request) {
      unawaited(
        _handleRequest(
          request,
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

    await _serveRemoteRange(
      response,
      range: range,
      httpClient: httpClient,
      downloadUri: downloadUri,
      accessToken: accessToken,
      key: key,
      iv: iv,
    );
    await response.close();
  } catch (_) {
    // Players routinely abandon one request when seeking to another. Closing
    // only that response keeps the local stream server available for the new
    // request without turning an ordinary seek into a visible error.
    try {
      await response.close();
    } catch (_) {}
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
