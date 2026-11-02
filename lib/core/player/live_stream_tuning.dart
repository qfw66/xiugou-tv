/// 直播 / 点播两类会话的 mpv 网络缓冲参数与直播断流重连策略。
///
/// 纯逻辑（不依赖原生 mpv），由 [MpvPlayerEngine] 在每次 `open` 前按会话类型写入，
/// 便于单元测试锁定取值。
library;

/// 每次打开媒体前按会话类型写入的 mpv 属性。
///
/// - `cache-on-disk`：media_kit 默认 `yes`，会把解复用缓存落到临时文件；直播是实时流，
///   落盘只增加 I/O 抖动而没有回看收益，直播关闭、点播保持 media_kit 默认。
/// - `cache-pause-wait`：缓存欠载后恢复播放前至少攒够的秒数。mpv 默认 1s，直播网络
///   抖动时会出现「播 1 秒卡一下」的连续微卡；直播攒 3s 再恢复，卡顿次数显著减少。
/// - `network-timeout`：直播 15s 无数据即报错，交给断流重连；点播保持 60s（④ 诊断约定）。
/// - `stream-lavf-o`：让 ffmpeg http 层对直播流断开自动重连（HLS 分片重试由 media_kit
///   的 `seg_max_retry=5` 负责）。点播写空串恢复默认。
/// - `demuxer-max-bytes`：预读上限。全局是 16 MB（⑥ 内存批）；`cache-secs`（默认 30s）的预读
///   会先撞上这个字节上限 —— 4K 网盘片约 2 MB/s，16 MB 只够预读 8 秒，CDN 一抖就「播到哪
///   加载到哪」（§57 用户反馈）。点播放到 64 MiB 让 30 秒预读真正生效；直播是实时流，保持 16 MB。
Map<String, String> sessionStreamProperties({required bool isLive}) => isLive
    ? const {
        'cache-on-disk': 'no',
        'cache-pause-wait': '3',
        'network-timeout': '15',
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5',
        'demuxer-max-bytes': '16777216', // 16 MiB
      }
    : const {
        'cache-on-disk': 'yes',
        'cache-pause-wait': '1',
        'network-timeout': '60',
        'stream-lavf-o': '',
        'demuxer-max-bytes': '67108864', // 64 MiB
      };

/// ffmpeg 允许的协议（media_kit 默认值 + `httpproxy`）。
///
/// §58：系统设置了 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量（Clash 等代理软件常见，本机实测
/// `http://127.0.0.1:7890`）时，ffmpeg 通过代理访问 https 要走内部的 `httpproxy` 协议建隧道；
/// media_kit 默认白名单没有它，于是 https 的 HLS 子列表 / 分片全部打不开 ——
/// 2026-11-01 用真实 libmpv-2.dll 对肥猫「干饭」同一集逐线对照：默认白名单下「超级无敌4K」时长
/// 只认出 4 秒、播 6 秒就结束，「高清蓝光4K」直接打不开，「B超高清」认不出时长、10 秒结束；
/// 加上 `httpproxy` 后三条都能识别 53 分钟全长并正常预读 30 秒。这就是「线路播放不了」和
/// 「时间轴像直播一样一点点加载」的全局根因之一。只放开代理隧道协议，不放开其它协议。
const List<String> mpvProtocolWhitelist = [
  'udp',
  'rtp',
  'tcp',
  'tls',
  'data',
  'file',
  'http',
  'https',
  'crypto',
  'httpproxy',
];

/// 每次起播写入的倍速：点播用设置里的「默认倍速」，直播固定 1x。
double sessionPlaybackRate({required bool isLive, required double defaultRate}) =>
    isLive ? 1.0 : defaultRate;

/// 直播断流（错误 / 意外 EOF）后的重开退避策略。
///
/// 连续失败按 [delays] 依次退避，用尽后放弃并交由界面显示错误；
/// 重开后位置稳定推进 [stableThreshold] 视为恢复，计数清零。
class LiveReconnectPolicy {
  final List<Duration> delays;
  final Duration stableThreshold;

  int _attempts = 0;
  Duration? _baseline;

  LiveReconnectPolicy({
    this.delays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.stableThreshold = const Duration(seconds: 10),
  });

  int get attempts => _attempts;

  /// 下一次重连前的等待时长；返回 null 表示已用尽，应上报错误。
  Duration? nextDelay() {
    if (_attempts >= delays.length) return null;
    final delay = delays[_attempts];
    _attempts++;
    _baseline = null;
    return delay;
  }

  /// 播放位置回调：重连后推进足够久即清零计数。
  void onPosition(Duration position) {
    if (_attempts == 0) return;
    final baseline = _baseline ??= position;
    if (position - baseline >= stableThreshold) reset();
  }

  /// 新会话（换台 / 停止）时调用。
  void reset() {
    _attempts = 0;
    _baseline = null;
  }
}
