import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:patrick_messenger/services/giphy_client.dart';

void main() {
  test('search requests PG-13 messaging GIFs and parses HTTPS renditions', () {
    final httpClient = MockClient((request) async {
      expect(request.url.host, 'api.giphy.com');
      expect(request.url.path, '/v1/gifs/search');
      expect(request.url.queryParameters['api_key'], 'test-key');
      expect(request.url.queryParameters['q'], 'thumbs up');
      expect(request.url.queryParameters['rating'], 'pg-13');
      expect(request.url.queryParameters['bundle'], 'messaging_non_clips');
      return http.Response(
        jsonEncode({
          'data': [
            {
              'id': 'abc123',
              'title': 'Thumbs up',
              'images': {
                'fixed_width_small': {
                  'url': 'https://media.example/preview.gif',
                },
                'downsized_medium': {
                  'url': 'https://media.example/download.gif',
                },
              },
            },
          ],
        }),
        200,
      );
    });
    final client = GiphyClient(apiKey: 'test-key', httpClient: httpClient);
    addTearDown(client.close);

    expect(
      client.search('thumbs up'),
      completion(
        isA<List<PublicGif>>()
            .having((gifs) => gifs.single.id, 'id', 'abc123')
            .having(
              (gifs) => gifs.single.downloadUrl.toString(),
              'download URL',
              'https://media.example/download.gif',
            ),
      ),
    );
  });

  test('parser rejects non-HTTPS media URLs', () {
    final gifs = parseGiphyResponse({
      'data': [
        {
          'id': 'unsafe',
          'images': {
            'fixed_width': {'url': 'http://media.example/preview.gif'},
            'original': {'url': 'http://media.example/download.gif'},
          },
        },
      ],
    });

    expect(gifs, isEmpty);
  });

  test('an API key is required before requests are made', () {
    final client = GiphyClient(apiKey: '');
    addTearDown(client.close);

    expect(client.trending(), throwsA(isA<GiphyException>()));
  });
}
