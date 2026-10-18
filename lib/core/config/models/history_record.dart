/// 播放历史记录模型
class HistoryRecord {
  final String id;
  final String vodId;
  final String vodName;
  final String vodPic;
  final String episodeName;
  final String sourceName;

  /// 上次解析得到的可播放直链（可能已过期，仅作续播兜底）
  final String playUrl;

  /// 选集原始地址（未经解析器处理）；续播时优先据此重新解析，避免直链过期
  final String episodeUrl;
  final String? siteKey;
  final String? siteName;
  final int timestamp;
  final int positionMs;
  final int durationMs;

  const HistoryRecord({
    required this.id,
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.episodeName,
    required this.sourceName,
    required this.playUrl,
    this.episodeUrl = '',
    this.siteKey,
    this.siteName,
    required this.timestamp,
    this.positionMs = 0,
    this.durationMs = 0,
  });

  /// 历史记录 ID 契约：同一影片 + 同一选集共享一条记录（用于断点续播查找）
  static String buildId(String vodId, String episodeName) => '${vodId}_$episodeName';

  /// 观看进度比例 (0.0 ~ 1.0)；时长未知时返回 0
  double get progress {
    if (durationMs <= 0 || positionMs <= 0) return 0.0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  /// 是否存在可用于断点续播的位置
  bool get hasResumePosition => positionMs > 0;

  /// 是否已播放到片尾（位置抵达总时长，允许 1s 误差）。
  ///
  /// 仅用于避免「从片尾续播 → 立即完成」的死循环；不是「≥95% 视为看完」的宽松判定，
  /// 停在最后几秒仍会从该位置继续。
  bool get isFinished =>
      durationMs > 0 && positionMs >= durationMs - _finishToleranceMs;

  static const int _finishToleranceMs = 1000;

  /// 断点续播起始位置（无记录或已播完时为 null，表示从头播放）
  Duration? get resumePosition =>
      hasResumePosition && !isFinished ? Duration(milliseconds: positionMs) : null;

  HistoryRecord copyWith({
    String? id,
    String? vodId,
    String? vodName,
    String? vodPic,
    String? episodeName,
    String? sourceName,
    String? playUrl,
    String? episodeUrl,
    String? siteKey,
    String? siteName,
    int? timestamp,
    int? positionMs,
    int? durationMs,
  }) {
    return HistoryRecord(
      id: id ?? this.id,
      vodId: vodId ?? this.vodId,
      vodName: vodName ?? this.vodName,
      vodPic: vodPic ?? this.vodPic,
      episodeName: episodeName ?? this.episodeName,
      sourceName: sourceName ?? this.sourceName,
      playUrl: playUrl ?? this.playUrl,
      episodeUrl: episodeUrl ?? this.episodeUrl,
      siteKey: siteKey ?? this.siteKey,
      siteName: siteName ?? this.siteName,
      timestamp: timestamp ?? this.timestamp,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  factory HistoryRecord.fromJson(Map<String, dynamic> json) {
    return HistoryRecord(
      id: json['id']?.toString() ?? '',
      vodId: json['vodId']?.toString() ?? '',
      vodName: json['vodName']?.toString() ?? '',
      vodPic: json['vodPic']?.toString() ?? '',
      episodeName: json['episodeName']?.toString() ?? '正片',
      sourceName: json['sourceName']?.toString() ?? '默认',
      playUrl: json['playUrl']?.toString() ?? '',
      episodeUrl: json['episodeUrl']?.toString() ?? '',
      siteKey: json['siteKey']?.toString(),
      siteName: json['siteName']?.toString(),
      timestamp: _toInt(json['timestamp']) ?? DateTime.now().millisecondsSinceEpoch,
      positionMs: _toInt(json['positionMs']) ?? 0,
      durationMs: _toInt(json['durationMs']) ?? 0,
    );
  }

  /// 安全整数转换：兼容 num 与数字字符串，非法值返回 null
  static int? _toInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'vodId': vodId,
    'vodName': vodName,
    'vodPic': vodPic,
    'episodeName': episodeName,
    'sourceName': sourceName,
    'playUrl': playUrl,
    if (episodeUrl.isNotEmpty) 'episodeUrl': episodeUrl,
    if (siteKey != null) 'siteKey': siteKey,
    if (siteName != null) 'siteName': siteName,
    'timestamp': timestamp,
    'positionMs': positionMs,
    'durationMs': durationMs,
  };
}
