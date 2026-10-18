import 'dart:convert';

import '../config_decoder.dart';

/// 站点定义模型
class Site {
  final String key;
  final String name;
  final int type;
  final String api;
  final int searchable;
  final int quickSearch;
  final int filterable;
  final String? ext;
  final String? jar;
  final String? playUrl;
  final List<String>? categories;
  final Map<String, String>? header;

  const Site({
    required this.key,
    required this.name,
    this.type = 0,
    required this.api,
    this.searchable = 1,
    this.quickSearch = 1,
    this.filterable = 1,
    this.ext,
    this.jar,
    this.playUrl,
    this.categories,
    this.header,
  });

  /// 与手机端 `BaseLoader.getSpider` 的 api 判定对齐：
  /// `.js` 走 JS 引擎、`.py` 走 Python 引擎、`csp_` 走 JAR；
  /// `type == 3` 是历史约定，配置里并非所有 spider 站源都标注它。
  bool get isJavaScriptSource => api.contains('.js');

  bool get isPythonSource => api.contains('.py');

  bool get isJarSource => api.startsWith('csp_');

  /// 需要 Spider 执行环境（Companion）的站源；Python 源同样需要，但当前无引擎。
  bool get usesCompanion =>
      type == 3 || isJavaScriptSource || isPythonSource || isJarSource;

  /// 当前桌面端无法执行的站源（缺少 Chaquopy 等运行时）。
  bool get isUnsupportedSource => isPythonSource;

  factory Site.fromJson(Map<String, dynamic> json, {String? defaultSpider}) {
    Map<String, String>? parsedHeader;
    if (json['header'] is Map) {
      parsedHeader = (json['header'] as Map).map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }

    final rawJar = json['jar']?.toString();
    final jar = (rawJar != null && rawJar.isNotEmpty) ? rawJar : defaultSpider;

    // ext 在真实配置里有三种形态：字符串、脚本 URL、JSON 对象/数组。
    // 对象形态必须序列化成合法 JSON（手机端 ExtAdapter 行为），
    // 否则 `Map.toString()` 产出的 `{k: v}` 会让下游 JSON 解析失败。
    final rawExt = json['ext'];
    final ext = switch (rawExt) {
      null => null,
      Map() || List() => jsonEncode(rawExt),
      _ => rawExt.toString(),
    };

    return Site(
      key: json['key']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      type: _asInt(json['type']),
      api: json['api']?.toString() ?? '',
      searchable: _asInt(json['searchable'], fallback: 1),
      quickSearch: _asInt(json['quickSearch'], fallback: 1),
      filterable: _asInt(json['filterable'], fallback: 1),
      ext: ext,
      jar: jar,
      playUrl: json['playUrl']?.toString(),
      categories: (json['categories'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      header: parsedHeader,
    );
  }

  Site copyWith({
    String? name,
    int? type,
    String? api,
    String? ext,
    String? jar,
  }) =>
      Site(
        key: key,
        name: name ?? this.name,
        type: type ?? this.type,
        api: api ?? this.api,
        searchable: searchable,
        quickSearch: quickSearch,
        filterable: filterable,
        ext: ext ?? this.ext,
        jar: jar ?? this.jar,
        playUrl: playUrl,
        categories: categories,
        header: header,
      );

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'type': type,
    'api': api,
    'searchable': searchable,
    'quickSearch': quickSearch,
    'filterable': filterable,
    if (ext != null) 'ext': ext,
    if (jar != null) 'jar': jar,
    if (playUrl != null) 'playUrl': playUrl,
    if (categories != null) 'categories': categories,
    if (header != null) 'header': header,
  };

  /// 调试输出：`print(site)` / `debugPrint('$site')` 可直接打印全部关键字段。
  @override
  String toString() =>
      'Site(key: $key, name: $name, type: $type, api: $api, '
      'searchable: $searchable, quickSearch: $quickSearch, filterable: $filterable, '
      'ext: $ext, jar: $jar, playUrl: $playUrl, header: $header)';
}

/// 解析规则模型
class Parse {
  final String name;
  final int type;
  final String url;
  final String? ext;
  final Map<String, String>? header;

  const Parse({
    required this.name,
    this.type = 0,
    required this.url,
    this.ext,
    this.header,
  });

  factory Parse.fromJson(Map<String, dynamic> json) {
    Map<String, String>? parsedHeader;
    if (json['header'] is Map) {
      parsedHeader = (json['header'] as Map).map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }
    return Parse(
      name: json['name']?.toString() ?? '',
      type: _asInt(json['type']),
      url: json['url']?.toString() ?? '',
      ext: json['ext']?.toString(),
      header: parsedHeader,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'url': url,
    if (ext != null) 'ext': ext,
    if (header != null) 'header': header,
  };
}

/// 直播频道或待展开的直播清单；清单不能直接作为播放器输入。
class Live {
  final String name;
  final String url;
  final String? group;
  final String? logo;
  final String? epg;
  final String? epgId;
  final String? epgName;
  final Map<String, String> headers;
  final bool isPlaylist;

  const Live({
    required this.name,
    required this.url,
    this.group,
    this.logo,
    this.epg,
    this.epgId,
    this.epgName,
    this.headers = const {},
    this.isPlaylist = false,
  });

  String get groupName => _liveText(group) ?? '未分组';
  String get key => '$groupName\u0000$name\u0000$url';

  String? get logoUrl {
    final template = logo;
    if (template == null) return null;
    return _replaceLiveToken(
      _replaceLiveToken(template, 'id', epgId ?? name),
      'name',
      epgName ?? name,
    );
  }

  factory Live.fromJson(
    Map<String, dynamic> json, {
    String? defaultEpg,
    String? defaultLogo,
  }) {
    final urls = json['urls'];
    final url = _liveText(json['url']) ??
        (urls is List && urls.isNotEmpty ? _liveText(urls.first) : null) ??
        '';
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final rawHeaders = json['headers'] ?? json['header'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key.toString();
        final value = entry.value?.toString() ?? '';
        if (!key.contains(RegExp(r'[\r\n]')) &&
            !value.contains(RegExp(r'[\r\n]'))) {
          headers[key] = value;
        }
      }
    }
    if (_liveText(json['ua']) case final ua?) headers['User-Agent'] = ua;
    if (_liveText(json['referer']) case final referer?) {
      headers['Referer'] = referer;
    }
    return Live(
      name: _liveText(json['name']) ?? _liveText(json['channel']) ?? '',
      url: url,
      group: _liveText(json['group']) ?? _liveText(json['groupName']),
      logo: _inheritLiveTemplate(
        _liveText(json['logo']) ?? _liveText(json['tvg-logo']), defaultLogo, 'logo'),
      epg: _inheritLiveTemplate(_liveText(json['epg']), defaultEpg, 'epg'),
      epgId: _liveText(json['epgId']) ??
          _liveText(json['tvg-id']) ??
          _liveText(json['tvgId']),
      epgName: _liveText(json['epgName']) ??
          _liveText(json['tvg-name']) ??
          _liveText(json['tvgName']),
      headers: Map.unmodifiable(headers),
      isPlaylist: json['isPlaylist'] is bool
          ? json['isPlaylist'] as bool
          : json.containsKey('type') ||
              path.endsWith('.m3u') ||
              path.endsWith('.txt'),
    );
  }

  Live copyWith({
    String? url,
    String? group,
    String? logo,
    String? epg,
    Map<String, String>? headers,
    bool? isPlaylist,
  }) => Live(
    name: name,
    url: url ?? this.url,
    group: group ?? this.group,
    logo: logo ?? this.logo,
    epg: epg ?? this.epg,
    epgId: epgId,
    epgName: epgName,
    headers: headers ?? this.headers,
    isPlaylist: isPlaylist ?? this.isPlaylist,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    if (group != null) 'group': group,
    if (logo != null) 'logo': logo,
    if (epg != null) 'epg': epg,
    if (epgId != null) 'epgId': epgId,
    if (epgName != null) 'epgName': epgName,
    if (headers.isNotEmpty) 'headers': headers,
    'isPlaylist': isPlaylist,
  };
}

String _replaceLiveToken(String template, String token, String value) =>
    template.replaceAll(
      RegExp(r'(\{|%7B)' + token + r'(\}|%7D)', caseSensitive: false),
      Uri.encodeComponent(value),
    );

String? _inheritLiveTemplate(String? value, String? template, String token) {
  if (template == null || !RegExp(r'\{|%7B', caseSensitive: false).hasMatch(template)) {
    return value ?? template;
  }
  // 完整频道地址优先；频道 token 先套用源模板，再由调用方解析相对地址。
  if (value != null &&
      ((Uri.tryParse(value)?.hasScheme ?? false) || value.startsWith('//'))) {
    return value;
  }
  return _replaceLiveToken(template, token, value ?? '');
}

String? _liveText(dynamic value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

/// 规则标志模型
class FlagRule {
  final String name;
  final List<String> hosts;
  final List<String> regex;

  const FlagRule({
    required this.name,
    this.hosts = const [],
    this.regex = const [],
  });

  factory FlagRule.fromJson(Map<String, dynamic> json) {
    return FlagRule(
      name: json['name']?.toString() ?? '',
      hosts: (json['hosts'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      regex: (json['regex'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'hosts': hosts,
    'regex': regex,
  };
}

/// TVBox 影视配置总集模型
class VodConfig {
  final String? spider;
  final String? wallpaper;
  final String? warning;
  final List<Site> sites;
  final List<Parse> parses;
  final List<Live> lives;
  final List<FlagRule> rules;
  final List<String> flags;
  final List<String> ads;

  const VodConfig({
    this.spider,
    this.wallpaper,
    this.warning,
    this.sites = const [],
    this.parses = const [],
    this.lives = const [],
    this.rules = const [],
    this.flags = const [],
    this.ads = const [],
  });

  factory VodConfig.empty() => const VodConfig();

  factory VodConfig.fromJson(Map<String, dynamic> json) {
    final rawSpider = json['spider']?.toString();
    final rawSites = json['sites'] as List<dynamic>? ?? [];
    final rawParses = json['parses'] as List<dynamic>? ?? [];
    final rawLives = json['lives'] as List<dynamic>? ?? [];
    final rawRules = json['rules'] as List<dynamic>? ?? [];
    final rawFlags = json['flags'] as List<dynamic>? ?? [];
    final rawAds = json['ads'] as List<dynamic>? ?? [];

    return VodConfig(
      spider: rawSpider,
      wallpaper: json['wallpaper']?.toString(),
      warning: json['warning']?.toString(),
      sites: rawSites
          .whereType<Map<String, dynamic>>()
          .map((m) => Site.fromJson(m, defaultSpider: rawSpider))
          .toList(),
      parses: rawParses
          .whereType<Map<String, dynamic>>()
          .map(Parse.fromJson)
          .toList(),
      lives: _parseLives(rawLives),
      rules: rawRules
          .whereType<Map<String, dynamic>>()
          .map(FlagRule.fromJson)
          .toList(),
      flags: rawFlags.map((e) => e.toString()).toList(),
      ads: rawAds.map((e) => e.toString()).toList(),
    );
  }

  static List<Live> _parseLives(List<dynamic> list) {
    final result = <Live>[];

    void visit(
      Map<String, dynamic> item, {
      String? group,
      String? epg,
      String? logo,
      Map<String, String> headers = const {},
      bool channel = false,
    }) {
      final own = Live.fromJson(item);
      final inheritedEpg = own.epg ?? epg;
      final inheritedLogo = own.logo ?? logo;
      final inheritedHeaders = {...headers, ...own.headers};
      final groups = item['groups'];
      final channels = item['channels'];
      if (groups is List || channels is List) {
        final children = groups is List ? groups : channels as List;
        final childGroup = channels is List
            ? own.group ?? _liveText(item['name']) ?? group
            : own.group ?? group;
        for (final child in children.whereType<Map<String, dynamic>>()) {
          visit(
            child,
            group: childGroup,
            epg: inheritedEpg,
            logo: inheritedLogo,
            headers: inheritedHeaders,
            channel: channels is List,
          );
        }
      } else if (own.url.isNotEmpty) {
        result.add(own.copyWith(
          group: own.group ?? group,
          epg: _inheritLiveTemplate(own.epg, epg, 'epg'),
          logo: _inheritLiveTemplate(own.logo, logo, 'logo'),
          headers: Map.unmodifiable(inheritedHeaders),
          isPlaylist: channel ? false : own.isPlaylist,
        ));
      }
    }

    for (final item in list.whereType<Map<String, dynamic>>()) {
      visit(item);
    }
    return result;
  }

  /// 将纯文本、私有编码或 Base64 编码的配置解码为动态 Map 或 List。
  ///
  /// 具体载体识别（`<pre>` / 宽松 JSON / `**` Base64 / 整体 Base64）见
  /// [ConfigDecoder]；本方法只负责在失败时返回 null。
  static dynamic decodeRawString(String content) =>
      ConfigDecoder.decode(content);

  /// 支持从纯文本或 Base64 编码的配置中直接解析
  static VodConfig parseRawString(String content) {
    final decoded = ConfigDecoder.decode(content);
    if (decoded is Map<String, dynamic>) return VodConfig.fromJson(decoded);
    if (decoded is Map) return VodConfig.fromJson(Map<String, dynamic>.from(decoded));
    return VodConfig.empty();
  }

  Map<String, dynamic> toJson() => {
    if (spider != null) 'spider': spider,
    if (wallpaper != null) 'wallpaper': wallpaper,
    if (warning != null) 'warning': warning,
    'sites': sites.map((s) => s.toJson()).toList(),
    'parses': parses.map((p) => p.toJson()).toList(),
    'lives': lives.map((l) => l.toJson()).toList(),
    'rules': rules.map((r) => r.toJson()).toList(),
    'flags': flags,
    'ads': ads,
  };
}

int _asInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}
