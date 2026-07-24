import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class PublicGif {
  final String id;
  final String title;
  final Uri previewUrl;
  final Uri downloadUrl;

  const PublicGif({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.downloadUrl,
  });

  String get filename => 'giphy_$id.gif';
}

class GiphyClient {
  static const maximumDownloadBytes = 25 * 1024 * 1024;

  final String apiKey;
  final http.Client _httpClient;

  GiphyClient({required this.apiKey, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  bool get configured => apiKey.trim().isNotEmpty;

  Future<List<PublicGif>> trending() {
    return _request('/v1/gifs/trending', const {});
  }

  Future<List<PublicGif>> search(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return trending();
    return _request('/v1/gifs/search', {'q': trimmed});
  }

  Future<List<PublicGif>> _request(
    String path,
    Map<String, String> parameters,
  ) async {
    if (!configured) {
      throw const GiphyException('A GIPHY API key has not been configured.');
    }
    final uri = Uri.https('api.giphy.com', path, {
      'api_key': apiKey,
      'limit': '24',
      'rating': 'pg-13',
      'lang': 'en',
      'bundle': 'messaging_non_clips',
      ...parameters,
    });
    final response = await _httpClient.get(uri);
    if (response.statusCode != 200) {
      throw GiphyException('GIPHY returned HTTP ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const GiphyException('GIPHY returned an invalid response.');
    }
    return parseGiphyResponse(decoded);
  }

  Future<Uint8List> download(PublicGif gif) async {
    final request = http.Request('GET', gif.downloadUrl);
    final response = await _httpClient.send(request);
    if (response.statusCode != 200) {
      throw GiphyException(
        'The selected GIF returned HTTP ${response.statusCode}.',
      );
    }
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > maximumDownloadBytes) {
      throw const GiphyException('The selected GIF is larger than 25 MB.');
    }

    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response.stream) {
      length += chunk.length;
      if (length > maximumDownloadBytes) {
        throw const GiphyException('The selected GIF is larger than 25 MB.');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void close() => _httpClient.close();
}

List<PublicGif> parseGiphyResponse(Map<String, dynamic> response) {
  final data = response['data'];
  if (data is! List) {
    throw const GiphyException('GIPHY returned an invalid GIF list.');
  }

  final gifs = <PublicGif>[];
  for (final item in data) {
    if (item is! Map) continue;
    final id = item['id'];
    final images = item['images'];
    if (id is! String || id.isEmpty || images is! Map) continue;

    final preview = _renditionUrl(images, const [
      'fixed_width_small',
      'fixed_width',
      'downsized',
    ]);
    final download = _renditionUrl(images, const [
      'downsized_medium',
      'downsized',
      'original',
    ]);
    if (preview == null || download == null) continue;

    gifs.add(
      PublicGif(
        id: id,
        title: item['title'] is String ? item['title'] as String : 'GIF',
        previewUrl: preview,
        downloadUrl: download,
      ),
    );
  }
  return gifs;
}

Uri? _renditionUrl(Map<dynamic, dynamic> images, List<String> names) {
  for (final name in names) {
    final rendition = images[name];
    if (rendition is! Map) continue;
    final url = rendition['url'];
    if (url is! String) continue;
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.scheme == 'https' && parsed.host.isNotEmpty) {
      return parsed;
    }
  }
  return null;
}

class GiphyException implements Exception {
  final String message;

  const GiphyException(this.message);

  @override
  String toString() => message;
}
