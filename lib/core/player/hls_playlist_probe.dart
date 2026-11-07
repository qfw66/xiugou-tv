/// 直链 HLS 清单只读探测（P1）——判定「点播 / 直播」。
///
/// 设计约束（见 docs/PLAN_LIVE_DIRECT_SEEK_20261103.md §3）：
/// - **只读清单，不拉分片**：只请求 `.m3u8/.m3u`，不触碰 `.ts/.m4s`，避免计费 / 签名消耗；
/// - **硬预算**：总时长 ≤4 s（单跳建连 ≤3 s）、单跳 ≤512 KiB、最多 2 层（master → media）；
///   走代理的海外点播清单首跳实测 2–3 s，预算太紧会把点播误判成直播；
/// - **失败静默**：任何异常 / 超时 / 非 2xx / 非 HLS 内容一律回退 `live`（现状），绝不挡起播；
/// - **纯解析 + 可注入抓取**：[parseHlsSignals] / [decidePlaybackMode] 是纯函数，
///   [HlsPlaylistProbe] 通过 [HlsPlaylistFetch] 注入 IO，单测不联网。
///
/// 出口一致性：生产抓取必须走 [HttpClientFactory]（DoH + 系统代理），
/// 与 mpv 起播的出口保持一致，否则会出现「探测说点播、播放拉不到」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../bounded_map.dart';
import '../danmaku/danmaku_api.dart';
import '../net/http_client_factory.dart';
import 'models/player_state.dart';

/// 单跳抓取预算（总预算由 [HlsPlaylistProbe] 统一截断）。
class HlsFetchBudget {
  const HlsFetchBudget({required this.maxBytes, required this.timeout});

  /// 单跳最多读取的字节数（超出部分丢弃，不做 Range 请求）。
  final int maxBytes;

  /// 单跳超时（已被总预算截断，不会超过剩余预算）。
  final Duration timeout;
}

/// 抓取结果（纯数据；重定向后的 [uri] 是解析相对变体地址的基址）。
class HlsFetchResponse {
  const HlsFetchResponse({
    required this.content,
    required this.uri,
    this.statusCode = 200,
  });

  final String content;
  final Uri uri;
  final int statusCode;
}

/// 可注入的抓取实现（测试用 fake，生产用 [fetchHlsPlaylist]）。
typedef HlsPlaylistFetch = Future<HlsFetchResponse> Function(
  Uri uri,
  Map<String, String> headers,
  HlsFetchBudget budget,
);

/// 抓取返回非 2xx 时抛出（探测侧据此记录状态码，不回传给 UI）。
class HlsProbeHttpException implements Exception {
  const HlsProbeHttpException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'HLS 清单请求返回 HTTP $statusCode';
}

/// master 清单里的一个变体。
class HlsVariant {
  const HlsVariant({required this.uri, required this.bandwidth});

  final Uri uri;

  /// `#EXT-X-STREAM-INF` 的 `BANDWIDTH`；缺失 / 非法为 0。
  final int bandwidth;
}

/// 清单里与「点播 / 直播」判定有关的全部信号（纯解析结果）。
class HlsPlaylistSignals {
  const HlsPlaylistSignals({
    required this.isMaster,
    required this.hasEndList,
    required this.playlistType,
    required this.mediaSequence,
    required this.totalDuration,
    required this.segmentCount,
    this.variants = const [],
  });

  /// 是否 master（含 `#EXT-X-STREAM-INF` 且有可用变体行）。
  final bool isMaster;

  /// 是否含 `#EXT-X-ENDLIST`（HLS 规范里「点播完成」的硬标志）。
  final bool hasEndList;

  /// `#EXT-X-PLAYLIST-TYPE` 的取值（`VOD` / `EVENT`，大写）；缺失为 null。
  final String? playlistType;

  /// `#EXT-X-MEDIA-SEQUENCE`（缺失为 0）。
  final int mediaSequence;

  /// `Σ #EXTINF`（分片总时长）。
  final Duration totalDuration;

  /// 出现 `#EXTINF` 的次数。
  final int segmentCount;

  /// master 的变体列表（已按 BANDWIDTH 升序，缺 BANDWIDTH 的排最后）。
  final List<HlsVariant> variants;

  /// 空清单 / 只有注释。
  bool get isEmpty => segmentCount == 0 && !isMaster && !hasEndList;
}

/// 判定结果（纯数据）。
class HlsPlaybackDecision {
  const HlsPlaybackDecision({
    required this.mode,
    required this.reason,
    this.suspicious = false,
    this.contentDuration,
  });

  final PlaybackMode mode;

  /// 判定依据（`endlist` / `playlist-type-vod` / `event` / `sliding-window` /
  /// `long-window-unfinished` / `unknown` …）。只写进诊断，不含敏感信息。
  final String reason;

  /// 「无 ENDLIST 的长窗口」：按直播处理但可疑，UI 应给手动逃生口。
  final bool suspicious;

  /// 清单声明的内容时长（`Σ #EXTINF`）。
  final Duration? contentDuration;

  bool get isVod => mode == PlaybackMode.vod;
}

/// 探针结果（含请求次数 / 状态码 / 是否失败，便于诊断与测试断言）。
class HlsProbeResult {
  const HlsProbeResult({
    required this.mode,
    required this.reason,
    this.suspicious = false,
    this.contentDuration,
    this.requests = 0,
    this.statusCode,
    this.failed = false,
    this.fromCache = false,
  });

  final PlaybackMode mode;
  final String reason;
  final bool suspicious;
  final Duration? contentDuration;

  /// 本次探测发出的清单请求数（缓存命中为 0）。
  final int requests;

  /// 最后一跳的 HTTP 状态码（未发出请求时为 null）。
  final int? statusCode;

  /// 探测失败（超时 / 非 2xx / 非 HLS / 网络异常）——按直播回退，且不写主机记忆。
  final bool failed;

  /// 是否命中内存缓存。
  final bool fromCache;

  bool get isVod => mode == PlaybackMode.vod;
}

/// 直链模式的最终决策（纯函数 [resolveDirectPlaybackMode] 的产物）。
class DirectPlaybackDecision {
  const DirectPlaybackDecision({
    required this.mode,
    required this.source,
    this.reason,
    this.suspicious = false,
  });

  final PlaybackMode mode;
  final PlaybackModeSource source;

  /// 依据 / 回退原因（诊断用，不含敏感信息）。
  final String? reason;

  /// 探测把流判成「可疑直播」（长窗口未结束）。
  final bool suspicious;
}

// --- URL 层判定（不联网） ---------------------------------------------------

/// 只能按直播处理的流协议（不在探测范围内）。
const Set<String> _liveOnlySchemes = {
  'rtmp',
  'rtmps',
  'rtsp',
  'rtsps',
  'udp',
  'rtp',
};

/// 明确是点播容器的扩展名（按扩展名直接点播，不必探测）。
const Set<String> _vodContainerExtensions = {
  'mp4',
  'mkv',
  'mov',
  'webm',
  'flv',
  'm4v',
  'avi',
};

/// 可探测的 HLS 清单扩展名。
const Set<String> _hlsPlaylistExtensions = {'m3u8', 'm3u'};

String _pathExtension(Uri? uri) {
  final path = uri?.path.toLowerCase() ?? '';
  final slash = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  if (dot <= slash || dot == path.length - 1) return '';
  return path.substring(dot + 1);
}

/// URL 层的点播提示：`file://` 与明确的容器扩展名 → [PlaybackMode.vod]。
///
/// `containerHint` 在决策表里优先于「主机记忆」，因为「用户点了按直播」也不该
/// 把 `.mp4` 当直播播（没有意义的组合）。
PlaybackMode? containerHintForUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  if (uri.scheme.toLowerCase() == 'file') return PlaybackMode.vod;
  if (_vodContainerExtensions.contains(_pathExtension(uri))) {
    return PlaybackMode.vod;
  }
  return null;
}

/// 是否值得联网探测：仅 `http(s)` 且路径以 `.m3u8` / `.m3u` 结尾。
///
/// `.mp4` 等容器按扩展名直接点播；`.ts` / 无扩展名按直播（保持现状）。
bool isHlsProbeCandidate(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return _hlsPlaylistExtensions.contains(_pathExtension(uri));
}

// --- 纯解析 -----------------------------------------------------------------

/// 解析清单头部的判定信号（纯函数，不联网、不抛异常）。
HlsPlaylistSignals parseHlsSignals(String content, Uri base) {
  var isMasterTag = false;
  var hasEndList = false;
  String? playlistType;
  var mediaSequence = 0;
  var totalMs = 0;
  var segmentCount = 0;
  final variants = <HlsVariant>[];
  int? pendingBandwidth;

  for (final rawLine in const LineSplitter().convert(content)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        isMasterTag = true;
        pendingBandwidth = _bandwidthOf(line);
      } else if (line.startsWith('#EXT-X-ENDLIST')) {
        hasEndList = true;
      } else if (line.startsWith('#EXT-X-PLAYLIST-TYPE:')) {
        final value = line
            .substring('#EXT-X-PLAYLIST-TYPE:'.length)
            .split(',')
            .first
            .trim()
            .toUpperCase();
        if (value.isNotEmpty) playlistType = value;
      } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        final value = line.substring('#EXT-X-MEDIA-SEQUENCE:'.length).trim();
        mediaSequence = int.tryParse(value.split(',').first.trim()) ?? 0;
      } else if (line.startsWith('#EXTINF:')) {
        segmentCount++;
        final value = line.substring('#EXTINF:'.length).split(',').first.trim();
        final seconds = double.tryParse(value);
        if (seconds != null && seconds.isFinite && seconds > 0) {
          totalMs += (seconds * 1000).round();
        }
      }
      continue;
    }
    // 非注释行：master 里是变体地址，media 里是分片地址（不下载）。
    if (pendingBandwidth != null) {
      final uri = base.resolve(line);
      if (uri.hasScheme) {
        variants.add(
            HlsVariant(uri: uri, bandwidth: pendingBandwidth));
      }
      pendingBandwidth = null;
    }
  }

  variants.sort((a, b) {
    final left = a.bandwidth > 0 ? a.bandwidth : 1 << 62;
    final right = b.bandwidth > 0 ? b.bandwidth : 1 << 62;
    return left.compareTo(right);
  });

  return HlsPlaylistSignals(
    isMaster: isMasterTag && variants.isNotEmpty,
    hasEndList: hasEndList,
    playlistType: playlistType,
    mediaSequence: mediaSequence,
    totalDuration: Duration(milliseconds: totalMs),
    segmentCount: segmentCount,
    variants: List.unmodifiable(variants),
  );
}

int? _bandwidthOf(String streamInfLine) {
  final match =
      RegExp(r'(?:^|[:,])BANDWIDTH=(\d+)', caseSensitive: false)
          .firstMatch(streamInfLine);
  final value = int.tryParse(match?.group(1) ?? '');
  return value == null || value <= 0 ? 0 : value;
}

/// 内容看起来是不是 HLS 清单（`#EXTM3U` 或至少一个 `#EXT-X-` 标签）。
bool looksLikeHlsPlaylist(String content) {
  final head = content.trimLeft();
  if (head.startsWith('#EXTM3U')) return true;
  return head.contains('#EXT-X-');
}

/// 判定表（docs/... §3.2）：自上而下，命中即返回；[signals] 为 null 表示探测失败。
///
/// 设计原则：**默认不改变现有行为**——判不出来一律 `live`。
HlsPlaybackDecision decidePlaybackMode(HlsPlaylistSignals? signals) {
  if (signals == null) {
    return const HlsPlaybackDecision(mode: PlaybackMode.live, reason: 'unknown');
  }
  if (signals.hasEndList) {
    return HlsPlaybackDecision(
        mode: PlaybackMode.vod,
        reason: 'endlist',
        contentDuration: signals.totalDuration);
  }
  if (signals.playlistType == 'VOD') {
    return HlsPlaybackDecision(
        mode: PlaybackMode.vod,
        reason: 'playlist-type-vod',
        contentDuration: signals.totalDuration);
  }
  if (signals.playlistType == 'EVENT') {
    return HlsPlaybackDecision(
        mode: PlaybackMode.live,
        reason: 'event',
        contentDuration: signals.totalDuration);
  }
  if (signals.mediaSequence > 0) {
    return HlsPlaybackDecision(
        mode: PlaybackMode.live,
        reason: 'sliding-window',
        contentDuration: signals.totalDuration);
  }
  // 无 ENDLIST、无类型标签、MEDIA-SEQUENCE == 0 但时长 ≥10 分钟：
  // 典型「分片表到结尾但没写 ENDLIST」的打包器产物 → 仍按直播（现状），
  // 只标记可疑，让 UI 给「按点播播放」逃生口。
  if (signals.totalDuration >= const Duration(minutes: 10)) {
    return HlsPlaybackDecision(
        mode: PlaybackMode.live,
        reason: 'long-window-unfinished',
        suspicious: true,
        contentDuration: signals.totalDuration);
  }
  return HlsPlaybackDecision(
      mode: PlaybackMode.live,
      reason: 'unknown',
      contentDuration: signals.totalDuration);
}

// --- 探针 -------------------------------------------------------------------

/// 直链 HLS 探针：只读清单 + 总预算 + 变体回退 + 内存缓存（≤32 条，不落盘）。
class HlsPlaylistProbe {
  HlsPlaylistProbe({
    HlsPlaylistFetch? fetch,
    this.budget = const Duration(seconds: 4),
    this.connectionTimeout = const Duration(seconds: 3),
    this.maxBytes = 512 * 1024,
    this.maxDepth = 2,
    this.maxVariants = 2,
    this.cacheSize = 32,
  }) : _fetch = fetch ?? fetchHlsPlaylist;

  final HlsPlaylistFetch _fetch;

  /// 探测总预算（用户点「开始播放」后的可接受等待上限）。
  final Duration budget;

  /// 单次建连超时（被 [budget] 截断）。
  final Duration connectionTimeout;

  /// 单跳最多读取字节数。
  final int maxBytes;

  /// 清单层级上限：master(1) → media(2)；不再跟随 media 里嵌套的 master。
  final int maxDepth;

  /// 最多尝试的变体数（第一个失败才换下一个）。
  final int maxVariants;

  /// 内存缓存条数（键为去掉 fragment 的完整 URL）。
  final int cacheSize;

  final Map<String, HlsProbeResult> _cache = {};

  /// 探测直链的播放方式；永不抛异常。
  Future<HlsProbeResult> probe(
    String url, {
    Map<String, String>? headers,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) {
      return const HlsProbeResult(
          mode: PlaybackMode.live, reason: 'probe-invalid-url', failed: true);
    }
    final scheme = uri.scheme.toLowerCase();
    if (_liveOnlySchemes.contains(scheme)) {
      return const HlsProbeResult(
          mode: PlaybackMode.live, reason: 'protocol');
    }
    if (scheme == 'file') {
      return const HlsProbeResult(
          mode: PlaybackMode.vod, reason: 'local-file');
    }
    final container = containerHintForUrl(url);
    if (container != null) {
      return const HlsProbeResult(
          mode: PlaybackMode.vod, reason: 'container');
    }
    if (!isHlsProbeCandidate(url)) {
      // 不是 .m3u8/.m3u：不联网，按现状直播（例如 .ts / 无扩展名）。
      return const HlsProbeResult(mode: PlaybackMode.live, reason: 'not-hls');
    }

    final cacheKey = url.trim().split('#').first;
    final cached = _cache[cacheKey];
    if (cached != null) {
      return HlsProbeResult(
        mode: cached.mode,
        reason: cached.reason,
        suspicious: cached.suspicious,
        contentDuration: cached.contentDuration,
        requests: 0,
        statusCode: cached.statusCode,
        failed: cached.failed,
        fromCache: true,
      );
    }

    final deadline = DateTime.now().add(budget);
    final requestHeaders = headers ?? const <String, String>{};
    var requests = 0;
    int? lastStatus;

    Future<HlsFetchResponse> fetchOne(Uri target) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException('探测预算已用尽');
      requests++;
      final hopBudget = HlsFetchBudget(
        maxBytes: maxBytes,
        timeout: remaining < connectionTimeout ? remaining : connectionTimeout,
      );
      return _fetch(target, requestHeaders, hopBudget).timeout(remaining);
    }

    try {
      final root = await fetchOne(uri);
      lastStatus = root.statusCode;
      if (!looksLikeHlsPlaylist(root.content)) {
        return _remember(
            cacheKey,
            HlsProbeResult(
              mode: PlaybackMode.live,
              reason: 'probe-invalid-content',
              requests: requests,
              statusCode: lastStatus,
              failed: true,
            ));
      }
      var signals = parseHlsSignals(root.content, root.uri);
      if (signals.isMaster) {
        HlsPlaylistSignals? media;
        for (final variant in signals.variants.take(maxVariants)) {
          if (maxDepth < 2) break;
          try {
            final response = await fetchOne(variant.uri);
            lastStatus = response.statusCode;
            if (!looksLikeHlsPlaylist(response.content)) continue;
            final parsed = parseHlsSignals(response.content, response.uri);
            if (parsed.isMaster) continue; // 不再跟随第二层 master
            media = parsed;
            break;
          } on HlsProbeHttpException catch (error) {
            lastStatus = error.statusCode;
            continue; // 变体 404/403：换下一个候选
          }
        }
        if (media == null) {
          // master 拉不到任何变体：按直播（现状），不算失败（不写记忆）。
          return _remember(
              cacheKey,
              HlsProbeResult(
                mode: PlaybackMode.live,
                reason: 'unknown',
                requests: requests,
                statusCode: lastStatus,
              ));
        }
        signals = media;
      }
      final decision = decidePlaybackMode(signals);
      return _remember(
          cacheKey,
          HlsProbeResult(
            mode: decision.mode,
            reason: decision.reason,
            suspicious: decision.suspicious,
            contentDuration: decision.contentDuration,
            requests: requests,
            statusCode: lastStatus,
          ));
    } on HlsProbeHttpException catch (error) {
      return _remember(
          cacheKey,
          HlsProbeResult(
            mode: PlaybackMode.live,
            reason: 'probe-http-${error.statusCode}',
            requests: requests,
            statusCode: error.statusCode,
            failed: true,
          ));
    } on TimeoutException {
      return HlsProbeResult(
        mode: PlaybackMode.live,
        reason: 'probe-timeout',
        requests: requests,
        statusCode: lastStatus,
        failed: true,
      );
    } catch (_) {
      return HlsProbeResult(
        mode: PlaybackMode.live,
        reason: 'probe-failed',
        requests: requests,
        statusCode: lastStatus,
        failed: true,
      );
    }
  }

  /// 只缓存「有结论」的结果：失败不缓存，避免一次抖动把主机钉死在直播模式。
  HlsProbeResult _remember(String key, HlsProbeResult result) {
    if (!result.failed) _cache.putBounded(key, result, cacheSize);
    return result;
  }

  void clearCache() => _cache.clear();
}

/// 生产抓取：只读清单首部，走 [HttpClientFactory]（DoH + 系统代理）与浏览器头。
///
/// 与 `MpvPlayerEngine` 的代理来源一致（[DanmakuApi.systemProxy]），保证
/// 「探测能过、播放也能过」；不发送 Range，靠读取上限截断。
Future<HlsFetchResponse> fetchHlsPlaylist(
  Uri uri,
  Map<String, String> headers,
  HlsFetchBudget budget,
) async {
  final client = HttpClientFactory.createHttpClient(
    connectionTimeout: budget.timeout,
    idleTimeout: HttpClientFactory.dioDefaultIdleTimeout,
    proxy: DanmakuApi.systemProxy,
  );
  try {
    final request = await client.getUrl(uri).timeout(budget.timeout);
    request.followRedirects = true;
    request.maxRedirects = 5;
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(budget.timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 读完并丢弃响应体，避免连接滞留。
      try {
        await response.drain<void>();
      } catch (_) {
        // 丢弃响应体失败不影响探测结论。
      }
      throw HlsProbeHttpException(response.statusCode);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(budget.timeout)) {
      final remain = budget.maxBytes - bytes.length;
      if (remain <= 0) break;
      if (chunk.length <= remain) {
        bytes.add(chunk);
      } else {
        bytes.add(chunk.sublist(0, remain));
      }
      if (bytes.length >= budget.maxBytes) break;
    }
    var resolved = uri;
    for (final redirect in response.redirects) {
      // RedirectInfo.location 是 Uri（与 live_text_loader 同样的逐跳解析）。
      resolved = resolved.resolveUri(redirect.location);
    }
    final text = utf8
        .decode(bytes.takeBytes(), allowMalformed: true)
        .replaceFirst('\uFEFF', '');
    return HlsFetchResponse(
        content: text, uri: resolved, statusCode: response.statusCode);
  } finally {
    client.close(force: true);
  }
}

/// 共享探针实例：直链弹窗共用一个内存缓存（进程内，不落盘）。
final HlsPlaylistProbe sharedHlsPlaylistProbe = HlsPlaylistProbe();

// --- 模式决策 ---------------------------------------------------------------

/// 决策前还差哪些信息？true = 需要先联网探测。
///
/// 已有手动选择 / 容器结论 / 主机记忆时都不探测（记忆命中即跳过，见方案 §3.3）。
bool shouldProbeDirectPlayback({
  required String url,
  PlaybackMode? manual,
  PlaybackMode? containerHint,
  PlaybackMode? remembered,
  required bool autoDetect,
}) {
  if (!autoDetect) return false;
  if (manual != null || containerHint != null || remembered != null) return false;
  return isHlsProbeCandidate(url);
}

/// 直链播放方式的唯一决策点（纯函数）。
///
/// 优先级：`manual` > `containerHint` > `remembered` > `probe` > `live`（默认）。
/// 唯一例外：容器本来就是点播（`.mp4` 等）却手动选「按直播」——这个组合没有意义，
/// 仍按点播（方案 §4.3 注 / §8.1「`.mp4` 不被按直播带偏」）。
DirectPlaybackDecision resolveDirectPlaybackMode({
  required String url,
  PlaybackMode? manual,
  PlaybackMode? containerHint,
  PlaybackMode? remembered,
  HlsProbeResult? probe,
}) {
  // 没显式传容器结论时按 URL 兜底（.mp4 等永远不该按直播播）。
  final hint = containerHint ?? containerHintForUrl(url);
  final nonsensicalManualLive =
      manual == PlaybackMode.live && hint == PlaybackMode.vod;
  if (manual != null && !nonsensicalManualLive) {
    return DirectPlaybackDecision(
      mode: manual,
      source: PlaybackModeSource.manual,
      reason: 'manual',
    );
  }
  if (hint != null) {
    return DirectPlaybackDecision(
      mode: hint,
      source: PlaybackModeSource.container,
      reason: 'container',
    );
  }
  if (remembered != null) {
    return DirectPlaybackDecision(
      mode: remembered,
      source: PlaybackModeSource.remembered,
      reason: 'remembered',
    );
  }
  if (probe != null) {
    return DirectPlaybackDecision(
      mode: probe.mode,
      source: PlaybackModeSource.probe,
      reason: probe.reason,
      suspicious: probe.suspicious,
    );
  }
  return const DirectPlaybackDecision(
    mode: PlaybackMode.live,
    source: PlaybackModeSource.defaultLive,
    reason: 'default-live',
  );
}
