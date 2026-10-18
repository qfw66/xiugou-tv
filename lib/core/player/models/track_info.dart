/// 轨道类型
enum TrackType {
  video,
  audio,
  subtitle,
}

/// 媒体轨道描述模型（音轨 / 字幕轨）
class TrackInfo {
  final String id;
  final TrackType type;
  final String? title;
  final String? language;
  final bool isSelected;

  const TrackInfo({
    required this.id,
    required this.type,
    this.title,
    this.language,
    this.isSelected = false,
  });

  String get displayName {
    if (title != null && title!.isNotEmpty) return title!;
    if (language != null && language!.isNotEmpty) return language!;
    return '轨道 $id';
  }

  @override
  String toString() => 'TrackInfo(id: $id, type: $type, displayName: $displayName, isSelected: $isSelected)';
}
