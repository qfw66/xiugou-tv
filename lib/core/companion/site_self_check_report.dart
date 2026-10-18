import 'dart:convert';

/// 逐站自检（站点体检）结果模型。
///
/// 数据来自 Java 侧 `SiteSelfCheck.run` 的 JSON：
/// ```json
/// {"summary":{"total":0,"ok":0,"degraded":0,"failed":0,"timeout":0},
///  "sites":[{"key":"","api":"","verdict":"OK","classes":0,"best":0,"ms":0,"error":""}]}
/// ```
/// verdict 取值：`OK`（有内容）/`DEGRADED`（有分类但取不到内容）/
/// `FAILED`（加载或请求报错）/`TIMEOUT`（单站超出预算）。
class SiteSelfCheckEntry {
  /// 站点标识（配置文件里的 key）
  final String key;

  /// 站点请求路径（api/csp_* 或 URL），便于在对不上配置时仍能定位
  final String api;

  /// 结论：OK / DEGRADED / FAILED / TIMEOUT
  final String verdict;

  /// 首页返回的分类数
  final int classes;

  /// 单个分类能取到的最大条数
  final int best;

  /// 本站在服务端的耗时（毫秒）
  final int ms;

  /// 失败原因（成功时为空串）
  final String error;

  /// 失败阶段（服务端 `stage` 字段：download/decrypt/proxy/class/…）
  /// 旧版 companion jar 不返回该字段，此时为空串，展示行为与以前一致。
  final String stage;

  const SiteSelfCheckEntry({
    required this.key,
    this.api = '',
    this.verdict = 'FAILED',
    this.classes = 0,
    this.best = 0,
    this.ms = 0,
    this.error = '',
    this.stage = '',
  });

  bool get isOk => verdict == 'OK';
  bool get isDegraded => verdict == 'DEGRADED';
  bool get isTimeout => verdict == 'TIMEOUT';

  /// 中文结论标签（界面展示用，不参与判定）
  String get verdictLabel {
    if (isOk) return '可用';
    if (isDegraded) return '降级';
    if (isTimeout) return '超时';
    return '失败';
  }

  /// 阶段中文标签（**仅供内部排查**，不要渲染到界面）。
  String get stageLabel {
    const labels = <String, String>{
      'resolve': '路径解析失败',
      'download': '下载失败',
      'md5': '校验失败',
      'decrypt': '解密失败',
      'dex2jar': '格式转换失败',
      'init': '初始化失败',
      'proxy': '本地代理未就绪',
      'class': '类未找到',
      'instantiate': '实例化失败',
      'call': '调用异常',
    };
    if (stage.isEmpty) return '';
    return labels[stage] ?? stage;
  }

  static SiteSelfCheckEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = (raw['key'] ?? '').toString().trim();
    if (key.isEmpty) return null;
    final error = (raw['error'] ?? '').toString();
    return SiteSelfCheckEntry(
      key: key,
      api: (raw['api'] ?? '').toString(),
      verdict: (raw['verdict'] ?? '').toString().trim().toUpperCase(),
      classes: _asInt(raw['classes']),
      best: _asInt(raw['best']),
      ms: _asInt(raw['ms']),
      // 服务端会把异常信息截断到 120~160 字符，这里再兜一层，避免弹窗出现超长单行
      error: error.length > 200 ? '${error.substring(0, 200)}…' : error,
      stage: (raw['stage'] ?? '').toString().trim(),
    );
  }

  static int _asInt(Object? value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;
}

/// 一次体检的完整结果（汇总 + 逐站明细）
class SelfCheckReport {
  final int total;
  final int ok;
  final int degraded;
  final int failed;
  final int timeout;
  final List<SiteSelfCheckEntry> sites;

  const SelfCheckReport({
    this.total = 0,
    this.ok = 0,
    this.degraded = 0,
    this.failed = 0,
    this.timeout = 0,
    this.sites = const [],
  });

  bool get isEmpty => sites.isEmpty;

  /// 是否存在需要用户关注的结果（失败或超时）
  bool get hasProblem => failed > 0 || timeout > 0;

  /// 解析 RPC 返回（容错：结构不符时返回 null，由调用方提示"未取得结果"）
  static SelfCheckReport? tryParse(Object? raw) {
    Object? decoded = raw;
    if (decoded is String) {
      if (decoded.trim().isEmpty) return null;
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return null;
      }
    }
    if (decoded is! Map) return null;

    final summary = decoded['summary'];
    final rawSites = decoded['sites'];
    final sites = <SiteSelfCheckEntry>[
      if (rawSites is List)
        for (final item in rawSites)
          if (SiteSelfCheckEntry.tryFromJson(item) case final entry?) entry,
    ];
    final summaryMap = summary is Map ? summary : const {};

    return SelfCheckReport(
      total: SiteSelfCheckEntry._asInt(summaryMap['total']) == 0
          ? sites.length
          : SiteSelfCheckEntry._asInt(summaryMap['total']),
      ok: SiteSelfCheckEntry._asInt(summaryMap['ok']),
      degraded: SiteSelfCheckEntry._asInt(summaryMap['degraded']),
      failed: SiteSelfCheckEntry._asInt(summaryMap['failed']),
      timeout: SiteSelfCheckEntry._asInt(summaryMap['timeout']),
      sites: List.unmodifiable(sites),
    );
  }
}
