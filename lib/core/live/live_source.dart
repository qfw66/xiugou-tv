import '../config/models/vod_config.dart';

/// 自定义直播源与最后一次成功解析的频道快照。
class LiveSource {
  final String id;
  final String name;
  final String? location;
  final String? epg;
  final List<Live> channels;

  const LiveSource({
    required this.id,
    required this.name,
    required this.channels,
    this.location,
    this.epg,
  });

  factory LiveSource.fromJson(Map<String, dynamic> json) => LiveSource(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '自定义直播',
        location: json['location']?.toString(),
        epg: json['epg']?.toString(),
        channels: List.unmodifiable(
          (json['channels'] is List ? json['channels'] as List : const [])
              .whereType<Map<String, dynamic>>()
              .map(Live.fromJson)
              .where(
                  (channel) => channel.url.isNotEmpty && !channel.isPlaylist),
        ),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (location != null) 'location': location,
        if (epg != null) 'epg': epg,
        'channels': channels.map((channel) => channel.toJson()).toList(),
      };
}

class LiveCatalog {
  final List<Live> channels;
  final List<String> warnings;

  const LiveCatalog({required this.channels, this.warnings = const []});
}
