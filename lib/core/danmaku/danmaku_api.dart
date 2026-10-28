import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/app_env.dart';
import 'danmaku_models.dart';

/// §43 弹幕服务地址与访问令牌：由维护者在 `config/app.env` 里配置，代码与仓库里不保存真实值。
///
/// - 面向用户：用户用的是维护者打包好的安装包（打包时自动注入），**不需要也看不到**这项配置；
/// - 维护者本机：`flutter run`（带不带其它参数都行）开发态会自动读 `config/app.env`，见 [AppEnv]；
/// - 其他开发者：这是留给你的「可选」口子——不建 `config/app.env` 就是不启用弹幕，
///   播放页没有弹幕按钮 / D 键、设置页没有「弹幕」分组、不发任何请求，其余功能照常；
/// - `config/app.env` 已被 `.gitignore` 排除，**不要提交**；入库的只有空值模板 `config/app.env.example`。
///
/// 服务是自部署的 LogVar Danmu API（https://github.com/qfw66/danmu_api），令牌放在路径第一段。
/// 注意：值会编进发布的 exe，只能防「拿仓库代码就能用」，挡不住拆包或抓包；防滥用靠服务端限流 / 换令牌。
String get kDanmakuApiBase => composeDanmakuApiBase(
    AppEnv.get('XIUGOU_DANMAKU_URL'), AppEnv.get('XIUGOU_DANMAKU_TOKEN'));

/// 是否配置了弹幕服务（为 false 时弹幕功能整体不出现）。
bool get danmakuServiceConfigured => kDanmakuApiBase.isNotEmpty;

/// `https://host/` + `tk` → `https://host/tk`；地址为空返回空串；令牌可空（服务未设令牌时）。
String composeDanmakuApiBase(String url, String token) {
  var base = url.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  if (base.isEmpty) return '';
  final t = token.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  return t.isEmpty ? base : '$base/$t';
}

/// 取不到弹幕的原因（只用于状态提示，不打断播放）。
class DanmakuException implements Exception {
  const DanmakuException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 可取消标记：换集 / 换线 / 退出时置位，在途请求立刻中止。
class DanmakuCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
    _listeners.clear();
  }

  void _onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

/// 弹幕服务客户端。
///
/// - 匹配：`GET <base>/danmaku?name=&episode=`（FongMi 兼容接口，候选已按片名 + 集数打分排序；
///   网盘文件名式集名如「[1.76 GB]01-4K.高码率.mkv」也能识别，实测见 docs/DANMAKU_PLAN.md §2）；
/// - 取数：候选 `url` 换成 `format=json`。
///
/// 网络：跟随 Windows 系统代理（`HttpClient.findProxyFromEnvironment` 不读注册表，
/// 这里显式读取，见 [systemProxy]），直连失败的网络环境下仍可用。
class DanmakuApi {
  DanmakuApi({String? base, HttpClient? client, String? Function()? proxy})
      : _base = _trimSlash(base ?? kDanmakuApiBase),
        _client = client ?? _defaultClient(proxy ?? systemProxy);

  static String _trimSlash(String s) => s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  final String _base;
  final HttpClient _client;

  static const Duration searchTimeout = Duration(seconds: 30);

  /// 单集弹幕可达 4 万条 / 4 MB，Serverless 冷启动 + 源站实抓实测 11–44 s。
  static const Duration commentTimeout = Duration(seconds: 90);

  static HttpClient _defaultClient(String? Function() proxy) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..userAgent = 'xiugou-tv';
    client.findProxy = (uri) {
      final p = proxy();
      return p == null || p.isEmpty ? 'DIRECT' : 'PROXY $p; DIRECT';
    };
    return client;
  }

  /// 按片名 + 集名搜索候选（已按匹配度排序）。
  Future<List<DanmakuCandidate>> search(String name, String episode,
      {DanmakuCancelToken? cancel}) async {
    final uri = Uri.parse('$_base/danmaku')
        .replace(queryParameters: {'name': name, 'episode': episode});
    final body = await _get(uri, searchTimeout, cancel);
    return DanmakuCandidate.listFromJson(jsonDecode(body));
  }

  /// 取某个候选的弹幕原始 JSON 文本（交给缓存层落盘，再由 [DanmakuTrack] 解析）。
  Future<String> fetchComments(DanmakuCandidate candidate, {DanmakuCancelToken? cancel}) =>
      _get(Uri.parse(candidate.jsonUrl), commentTimeout, cancel);

  Future<String> _get(Uri uri, Duration timeout, DanmakuCancelToken? cancel) async {
    if (cancel?.isCancelled ?? false) throw const DanmakuException('已取消');
    if (_base.isEmpty) throw const DanmakuException('未配置弹幕服务');
    HttpClientRequest? request;
    cancel?._onCancel(() => request?.abort());
    try {
      request = await _client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      final bytes = await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(timeout);
      if (cancel?.isCancelled ?? false) throw const DanmakuException('已取消');
      if (response.statusCode == HttpStatus.notFound) throw const DanmakuException('无弹幕');
      if (response.statusCode != HttpStatus.ok) {
        throw DanmakuException('弹幕服务返回 ${response.statusCode}');
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on DanmakuException {
      rethrow;
    } on TimeoutException {
      request?.abort();
      throw const DanmakuException('弹幕服务超时');
    } catch (e) {
      if (cancel?.isCancelled ?? false) throw const DanmakuException('已取消');
      throw DanmakuException('弹幕服务不可达（$e）');
    }
  }

  void close() => _client.close(force: true);

  /// Windows 系统代理（「设置 → 网络 → 代理」/ Clash 等写入的注册表项）。
  ///
  /// 只取 `ProxyEnable=1` 时的 `ProxyServer`；`http=a:1;https=b:2` 形式取 https 项。
  /// 读失败一律当作无代理（直连）。结果缓存 60 s，避免每个请求都起进程。
  static String? systemProxy() {
    final now = DateTime.now();
    if (_proxyCachedAt != null && now.difference(_proxyCachedAt!) < const Duration(seconds: 60)) {
      return _proxyCache;
    }
    _proxyCachedAt = now;
    _proxyCache = Platform.isWindows ? _readWindowsProxy() : null;
    return _proxyCache;
  }

  static String? _proxyCache;
  static DateTime? _proxyCachedAt;

  static String? _readWindowsProxy() {
    try {
      const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      final enable = Process.runSync('reg', ['query', key, '/v', 'ProxyEnable']);
      if (!RegExp(r'ProxyEnable\s+REG_DWORD\s+0x0*1\b').hasMatch('${enable.stdout}')) return null;
      final server = Process.runSync('reg', ['query', key, '/v', 'ProxyServer']);
      final m = RegExp(r'ProxyServer\s+REG_SZ\s+(\S+)').firstMatch('${server.stdout}');
      return m == null ? null : parseProxyServer(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  /// `127.0.0.1:7890` / `http=127.0.0.1:7890;https=127.0.0.1:7891` / `http://h:p` → `host:port`。
  static String? parseProxyServer(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.contains('=')) {
      final entries = <String, String>{};
      for (final part in value.split(';')) {
        final i = part.indexOf('=');
        if (i > 0) entries[part.substring(0, i).trim().toLowerCase()] = part.substring(i + 1).trim();
      }
      value = entries['https'] ?? entries['http'] ?? '';
      if (value.isEmpty) return null;
    }
    value = value.replaceFirst(RegExp(r'^[a-z]+://', caseSensitive: false), '');
    if (value.endsWith('/')) value = value.substring(0, value.length - 1);
    return RegExp(r'^[^\s:/]+:\d+$').hasMatch(value) ? value : null;
  }
}
