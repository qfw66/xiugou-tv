import 'package:flutter/foundation.dart';

/// 起播准备阶段的状态。
enum PlaybackPrepareStatus {
  /// 正在解析 / 拉起播放器（页内骨架态）。
  preparing,

  /// 解析或启动失败（留在页内，可重试）。
  failed,
}

/// 「播放意图」：用户点了某一集**之后立刻**就有了这个对象。
///
/// <p>存在意义：解析播放地址（弱网 3–5s）发生在页面跳转之前时，用户只会看到
/// 列表被点了一下然后没反应。先立意图 → 播放页立刻出现并渲染骨架 → 解析完成后
/// 用真实 `MediaPlaySpec` 接管；失败则停在页内给重试，而不是把用户丢回列表。
///
/// <p>只承载**展示信息**，不持有解析逻辑（避免把闭包塞进 provider 状态）。
@immutable
class PlaybackIntent {
  const PlaybackIntent({
    required this.title,
    this.subtitle,
    this.cover,
    this.status = PlaybackPrepareStatus.preparing,
    this.error,
  });

  /// 片名（骨架态的主标题）。
  final String title;

  /// 副标题，通常是「第 N 集 · 线路名」。
  final String? subtitle;

  /// 海报地址；为空时骨架显示占位块。
  final String? cover;

  final PlaybackPrepareStatus status;

  /// [PlaybackPrepareStatus.failed] 时的错误文案。
  final String? error;

  bool get isFailed => status == PlaybackPrepareStatus.failed;

  PlaybackIntent copyWith({
    String? title,
    String? subtitle,
    String? cover,
    PlaybackPrepareStatus? status,
    String? error,
  }) {
    return PlaybackIntent(
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      cover: cover ?? this.cover,
      status: status ?? this.status,
      error: error ?? this.error,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackIntent &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.cover == cover &&
      other.status == status &&
      other.error == error;

  @override
  int get hashCode => Object.hash(title, subtitle, cover, status, error);

  @override
  String toString() =>
      'PlaybackIntent($title, $subtitle, ${status.name}${error == null ? '' : ', $error'})';
}
