enum TmdbEndpoint {
  official('api.themoviedb.org'),
  mirror('api.tmdb.org');

  const TmdbEndpoint(this.host);
  final String host;
}

enum TmdbImageEndpoint {
  official('https://image.tmdb.org/t/p/'),
  pagesProxy('https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/');

  const TmdbImageEndpoint(this.baseUrl);
  final String baseUrl;

  static final _filePath = RegExp(r'^/[a-zA-Z0-9_-]+\.(?:jpg|png|webp)$');

  static String? filePath(Object? value) =>
      value is String && _filePath.hasMatch(value) ? value : null;

  String? urlFor(Object? path, String size) =>
      filePath(path) != null ? '$baseUrl$size$path' : null;
}

class TmdbPreferences {
  const TmdbPreferences({
    this.cinematic = false,
    this.endpoint = defaultEndpoint,
    this.imageEndpoint = defaultImageEndpoint,
    this.apiKey = '',
  });

  static const defaultEndpoint = TmdbEndpoint.mirror;
  static const defaultImageEndpoint = TmdbImageEndpoint.pagesProxy;

  final bool cinematic;
  final TmdbEndpoint endpoint;
  final TmdbImageEndpoint imageEndpoint;

  /// 只存个人覆盖值；内置密钥不写入用户数据或备份。
  final String apiKey;

  static bool acceptsKey(String value) =>
      value.isEmpty || RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(value);

  factory TmdbPreferences.fromJson(Object? value) {
    if (value == null) return const TmdbPreferences();
    if (value is! Map) throw const FormatException('影片详情设置格式无效');
    final cinematic = value['cinematic'] ?? false;
    final host = value['endpoint'] ?? defaultEndpoint.name;
    final imageRoute = value['imageEndpoint'] ?? defaultImageEndpoint.name;
    final key = value['apiKey'] ?? '';
    final endpoint = TmdbEndpoint.values
        .where((e) => e.name == host)
        .firstOrNull;
    final imageEndpoint = TmdbImageEndpoint.values
        .where((e) => e.name == imageRoute)
        .firstOrNull;
    if (cinematic is! bool ||
        endpoint == null ||
        imageEndpoint == null ||
        key is! String ||
        !acceptsKey(key)) {
      throw const FormatException('影片详情设置格式无效');
    }
    return TmdbPreferences(
      cinematic: cinematic,
      endpoint: endpoint,
      imageEndpoint: imageEndpoint,
      apiKey: key,
    );
  }

  Map<String, Object> toJson() => {
    'cinematic': cinematic,
    'endpoint': endpoint.name,
    'imageEndpoint': imageEndpoint.name,
    if (apiKey.isNotEmpty) 'apiKey': apiKey,
  };

  @override
  bool operator ==(Object other) =>
      other is TmdbPreferences &&
      cinematic == other.cinematic &&
      endpoint == other.endpoint &&
      imageEndpoint == other.imageEndpoint &&
      apiKey == other.apiKey;
  @override
  int get hashCode => Object.hash(cinematic, endpoint, imageEndpoint, apiKey);
}
