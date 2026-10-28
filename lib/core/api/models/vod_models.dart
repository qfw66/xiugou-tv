/// 影视点播摘要项（用于列表卡片展示与跨站聚合搜索）
class VodItem {
  final String id;
  final String name;
  final String pic;
  final String? remarks;
  final String? year;
  final String? area;
  final String? actor;
  final String? director;
  final String? content;
  final String? typeName;
  final String? score;
  final String? tag;
  final String? siteKey;
  final String? siteName;

  /// FongMi 的 `vod.action`：非空时点击条目不进详情，而是调用站源的 `action()`
  /// （配置中心的扫码登录 / 填写 cookie 等设置项就是这种条目）。
  final String? action;

  const VodItem({
    required this.id,
    required this.name,
    required this.pic,
    this.remarks,
    this.year,
    this.area,
    this.actor,
    this.director,
    this.content,
    this.typeName,
    this.score,
    this.tag,
    this.siteKey,
    this.siteName,
    this.action,
  });

  VodItem copyWith({
    String? id,
    String? name,
    String? pic,
    String? remarks,
    String? year,
    String? area,
    String? actor,
    String? director,
    String? content,
    String? typeName,
    String? score,
    String? tag,
    String? siteKey,
    String? siteName,
    String? action,
  }) {
    return VodItem(
      id: id ?? this.id,
      name: name ?? this.name,
      pic: pic ?? this.pic,
      remarks: remarks ?? this.remarks,
      year: year ?? this.year,
      area: area ?? this.area,
      actor: actor ?? this.actor,
      director: director ?? this.director,
      content: content ?? this.content,
      typeName: typeName ?? this.typeName,
      score: score ?? this.score,
      tag: tag ?? this.tag,
      siteKey: siteKey ?? this.siteKey,
      siteName: siteName ?? this.siteName,
      action: action ?? this.action,
    );
  }

  factory VodItem.fromJson(Map<String, dynamic> json) {
    final rawScore = json['vod_score']?.toString() ??
        json['vod_douban_score']?.toString() ??
        json['score']?.toString() ??
        json['rating']?.toString();

    final rawTag = json['vod_tag']?.toString() ??
        json['tag']?.toString() ??
        json['vod_class']?.toString();

    final rawAction = json['action']?.toString().trim();

    return VodItem(
      id: json['vod_id']?.toString() ?? json['id']?.toString() ?? '',
      name: json['vod_name']?.toString() ?? json['name']?.toString() ?? '',
      pic: json['vod_pic']?.toString() ?? json['pic']?.toString() ?? '',
      remarks: json['vod_remarks']?.toString() ?? json['remarks']?.toString() ?? json['note']?.toString(),
      year: json['vod_year']?.toString() ?? json['year']?.toString(),
      area: json['vod_area']?.toString() ?? json['area']?.toString(),
      actor: json['vod_actor']?.toString() ?? json['actor']?.toString(),
      director: json['vod_director']?.toString() ?? json['director']?.toString(),
      content: json['vod_content']?.toString() ?? json['content']?.toString() ?? json['des']?.toString(),
      typeName: json['type_name']?.toString() ?? json['type']?.toString(),
      score: (rawScore != null && rawScore.isNotEmpty && rawScore != '0' && rawScore != '0.0') ? rawScore : null,
      tag: (rawTag != null && rawTag.isNotEmpty) ? rawTag : null,
      siteKey: json['site_key']?.toString(),
      siteName: json['site_name']?.toString(),
      action: (rawAction != null && rawAction.isNotEmpty) ? rawAction : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'vod_id': id,
    'vod_name': name,
    'vod_pic': pic,
    if (remarks != null) 'vod_remarks': remarks,
    if (year != null) 'vod_year': year,
    if (area != null) 'vod_area': area,
    if (actor != null) 'vod_actor': actor,
    if (director != null) 'vod_director': director,
    if (content != null) 'vod_content': content,
    if (typeName != null) 'type_name': typeName,
    if (score != null) 'vod_score': score,
    if (tag != null) 'vod_tag': tag,
    if (siteKey != null) 'site_key': siteKey,
    if (siteName != null) 'site_name': siteName,
    if (action != null) 'action': action,
  };
}

/// 单集选集数据
class VodEpisode {
  final String name;
  final String url;

  const VodEpisode({
    required this.name,
    required this.url,
  });
}

/// 播放来源专线（如：腾讯视频、爱奇艺）
class PlayFrom {
  final String name;
  final List<VodEpisode> episodes;

  const PlayFrom({
    required this.name,
    required this.episodes,
  });
}

/// 影视点播详情（包含多播放源与各集选集列表）
class VodDetail {
  final VodItem item;
  final List<PlayFrom> sources;

  const VodDetail({
    required this.item,
    required this.sources,
  });

  factory VodDetail.fromJson(Map<String, dynamic> json) {
    final item = VodItem.fromJson(json);
    final sources = <PlayFrom>[];

    final rawFrom = json['vod_play_from']?.toString() ?? '';
    final rawUrl = json['vod_play_url']?.toString() ?? '';

    if (rawFrom.isNotEmpty && rawUrl.isNotEmpty) {
      final fromNames = rawFrom.split(r'$$$');
      final urlGroups = rawUrl.split(r'$$$');

      for (int i = 0; i < fromNames.length; i++) {
        final sourceName = fromNames[i].trim();
        final urlGroupStr = (i < urlGroups.length) ? urlGroups[i] : '';
        final episodes = <VodEpisode>[];

        final epList = urlGroupStr.split('#');
        for (final epStr in epList) {
          final trimmed = epStr.trim();
          if (trimmed.isEmpty) continue;

          if (trimmed.contains(r'$')) {
            final parts = trimmed.split(r'$');
            final epName = parts[0].trim();
            final epUrl = parts.sublist(1).join(r'$').trim();
            if (epUrl.isNotEmpty) {
              episodes.add(VodEpisode(name: epName, url: epUrl));
            }
          } else {
            episodes.add(VodEpisode(name: '正片', url: trimmed));
          }
        }

        if (episodes.isNotEmpty) {
          sources.add(PlayFrom(name: sourceName.isNotEmpty ? sourceName : '默认线路', episodes: episodes));
        }
      }
    }

    return VodDetail(
      item: item,
      sources: sources,
    );
  }

  /// 从 XML 格式解析影片详情与播放源选集
  factory VodDetail.fromXml(String xmlString, {String? siteKey, String? siteName}) {
    String extractTag(String xml, String tagName) {
      final match = RegExp('<$tagName(?:[^>]*)>(?:<\\!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?<\\/$tagName>', caseSensitive: false).firstMatch(xml);
      return match?.group(1)?.trim() ?? '';
    }

    final vMatch = RegExp(r'<video>([\s\S]*?)<\/video>', caseSensitive: false).firstMatch(xmlString);
    final vContent = vMatch?.group(1) ?? xmlString;

    final id = extractTag(vContent, 'id');
    final name = extractTag(vContent, 'name');
    final pic = extractTag(vContent, 'pic');
    final des = extractTag(vContent, 'des');
    final type = extractTag(vContent, 'type');
    final note = extractTag(vContent, 'note').isNotEmpty ? extractTag(vContent, 'note') : extractTag(vContent, 'state');
    final year = extractTag(vContent, 'year');
    final area = extractTag(vContent, 'area');
    final actor = extractTag(vContent, 'actor');
    final director = extractTag(vContent, 'director');

    final item = VodItem(
      id: id,
      name: name,
      pic: pic,
      remarks: note.isNotEmpty ? note : null,
      typeName: type.isNotEmpty ? type : null,
      content: des.isNotEmpty ? des : null,
      year: year.isNotEmpty ? year : null,
      area: area.isNotEmpty ? area : null,
      actor: actor.isNotEmpty ? actor : null,
      director: director.isNotEmpty ? director : null,
      siteKey: siteKey,
      siteName: siteName,
    );

    final sources = <PlayFrom>[];
    // 提取 <dd flag="线路名"><![CDATA[第01集$url#第02集$url]]></dd>
    final ddMatches = RegExp(r'<dd\s+flag="([^"]*)">(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/dd>', caseSensitive: false).allMatches(vContent);
    for (final dm in ddMatches) {
      final flag = dm.group(1)?.trim() ?? '默认线路';
      final urlsStr = dm.group(2)?.trim() ?? '';
      final episodes = <VodEpisode>[];
      final epList = urlsStr.split('#');
      for (final epStr in epList) {
        final trimmed = epStr.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.contains(r'$')) {
          final parts = trimmed.split(r'$');
          final epName = parts[0].trim();
          final epUrl = parts.sublist(1).join(r'$').trim();
          if (epUrl.isNotEmpty) {
            episodes.add(VodEpisode(name: epName, url: epUrl));
          }
        } else {
          episodes.add(VodEpisode(name: '正片', url: trimmed));
        }
      }
      if (episodes.isNotEmpty) {
        sources.add(PlayFrom(name: flag.isNotEmpty ? flag : '默认线路', episodes: episodes));
      }
    }

    return VodDetail(
      item: item,
      sources: sources,
    );
  }
}

/// 分类定义模型
class VodCategory {
  final String id;
  final String name;

  const VodCategory({
    required this.id,
    required this.name,
  });

  factory VodCategory.fromJson(Map<String, dynamic> json) {
    return VodCategory(
      id: json['type_id']?.toString() ??
          json['id']?.toString() ??
          json['class_id']?.toString() ??
          json['tid']?.toString() ??
          '',
      name: json['type_name']?.toString() ??
          json['name']?.toString() ??
          json['class_name']?.toString() ??
          json['tname']?.toString() ??
          '',
    );
  }

  Map<String, dynamic> toJson() => {
    'type_id': id,
    'type_name': name,
  };
}

/// 分页查询结果模型
class VodPageResult {
  final int page;
  final int pageCount;
  final int total;
  final int limit;
  final List<VodCategory> categories;
  final List<VodItem> list;

  const VodPageResult({
    this.page = 1,
    this.pageCount = 1,
    this.total = 0,
    this.limit = 20,
    this.categories = const [],
    this.list = const [],
  });

  const VodPageResult.empty()
      : page = 1,
        pageCount = 1,
        total = 0,
        limit = 20,
        categories = const [],
        list = const [];
}
