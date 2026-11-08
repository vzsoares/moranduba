import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Set at build time: `--dart-define=MORANDUBA_GIPHY_KEY=…`. Without it the
/// app hides GIPHY search.
const _key = String.fromEnvironment('MORANDUBA_GIPHY_KEY');

bool get giphyEnabled => _key.isNotEmpty;

class GiphyGif {
  const GiphyGif({
    required this.id,
    required this.title,
    required this.preview,
    required this.full,
    required this.width,
    required this.height,
  });

  final String id;
  final String title;

  /// Small animated preview for the picker.
  final String preview;

  /// What gets sent: GIPHY's downsized GIF, a few MB at most.
  final String full;
  final int width;
  final int height;

  static GiphyGif? fromJson(Object? json) => switch (json) {
    {
      'id': final String id,
      'images': {
        'fixed_width_small': {'url': final String preview},
        'downsized': {
          'url': final String full,
          'width': final String width,
          'height': final String height,
        },
      },
    } =>
      GiphyGif(
        id: id,
        title: switch (json['title']) {
          final String title => title,
          _ => '',
        },
        preview: preview,
        full: full,
        width: int.tryParse(width) ?? 0,
        height: int.tryParse(height) ?? 0,
      ),
    _ => null,
  };
}

/// GIPHY's search API. Each query and preview goes to GIPHY; what gets sent
/// is downloaded first and travels encrypted like any attachment.
class Giphy {
  Giphy({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<GiphyGif>> trending() => _list('trending', const {});

  Future<List<GiphyGif>> search(String query) => _list('search', {'q': query});

  Future<List<GiphyGif>> _list(String path, Map<String, String> query) async {
    final response = await _client.get(
      Uri.https('api.giphy.com', '/v1/gifs/$path', {
        'api_key': _key,
        'limit': '24',
        'rating': 'pg-13',
        ...query,
      }),
    );
    if (response.statusCode != 200) {
      throw http.ClientException('GIPHY answered ${response.statusCode}');
    }
    return switch (jsonDecode(response.body)) {
      {'data': final List<Object?> data} => [
        ...data.map(GiphyGif.fromJson).nonNulls,
      ],
      _ => const [],
    };
  }

  Future<Uint8List> download(GiphyGif gif) async {
    final response = await _client.get(Uri.parse(gif.full));
    if (response.statusCode != 200) {
      throw http.ClientException('GIPHY answered ${response.statusCode}');
    }
    return response.bodyBytes;
  }
}
