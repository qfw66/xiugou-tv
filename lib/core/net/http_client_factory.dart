import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'doh_resolver.dart';

/// 应用内 HTTP 客户端统一出口（§14）。
///
/// 所有 Dart 侧 `HttpClient` / `Dio` 都从这里创建，好处有二：
/// 1. 安全 DNS（DoH）只需在一处接入：开启后经 [HttpClient.connectionFactory] 按 DoH 解析出的 IP 建连，
///    **TLS 握手仍以原域名做 SNI 与证书校验**（`SecureSocket.secure(host: 原域名)`，不放宽任何校验）；
/// 2. 「跟随系统代理」的 PAC 串只写一份（原先弹幕 / 片段两处各写一遍）。
///
/// DoH 设置在运行中切换时，已创建的长生命周期客户端（豆瓣共享 Dio、海报 HttpClient 等）
/// 也会在下一次建连时使用新设置——连接工厂每次现读 [resolver]。
/// 走代理的请求由代理解析目标域名，不经 DoH。
class HttpClientFactory {
  HttpClientFactory._();

  static DohResolver? _resolver;

  /// 当前生效的 DoH 解析器；null 表示使用系统 DNS（默认）。
  static DohResolver? get resolver => _resolver;

  /// 按设置切换 DoH：[endpoint] 为 null 关闭；同一端点重复设置保留缓存。
  static void configureDoh(Uri? endpoint) {
    if (endpoint == null) {
      _resolver = null;
      return;
    }
    if (_resolver?.endpoint == endpoint) return;
    _resolver = DohResolver(endpoint: endpoint);
  }

  /// 让代码里没经过本工厂的 `HttpClient()`（如 Flutter `NetworkImage` 普通海报）也走 DoH。
  ///
  /// 只在应用启动时调用一次（main.dart）；不改代理与证书行为，仅接管建连。
  static void installGlobalOverrides() {
    HttpOverrides.global = _DohHttpOverrides();
  }

  /// 测试注入：直接指定解析器（null 恢复系统 DNS）。
  static set resolverForTesting(DohResolver? resolver) => _resolver = resolver;

  /// 把「返回代理地址的函数」转成 [HttpClient.findProxy] 用的 PAC 串：
  /// 有代理时优先代理、失败直连；无代理直连。
  static String pacFor(String? proxy) =>
      proxy == null || proxy.isEmpty ? 'DIRECT' : 'PROXY $proxy; DIRECT';

  /// 创建 [HttpClient]。
  ///
  /// [proxy] 每次请求现读（如 Windows 系统代理）；[context] 仅测试用于注入受信根，
  /// 生产代码不传，使用系统默认信任链。
  static HttpClient createHttpClient({
    Duration? connectionTimeout,
    Duration? idleTimeout,
    String? userAgent,
    String? Function()? proxy,
    SecurityContext? context,
  }) {
    final client = HttpClient(context: context);
    if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;
    if (idleTimeout != null) client.idleTimeout = idleTimeout;
    if (userAgent != null) client.userAgent = userAgent;
    if (proxy != null) client.findProxy = (_) => pacFor(proxy());
    client.connectionFactory = (uri, proxyHost, proxyPort) =>
        _connect(uri, proxyHost, proxyPort, context);
    return client;
  }

  /// dio 默认适配器自建 HttpClient 时设置的空闲连接保活时长（dio 5.x `IOHttpClientAdapter`）。
  ///
  /// 一旦传入 `createHttpClient`，dio 就不再设置它，HttpClient 会退回 15 s 默认值；
  /// 这里显式补回，保证迁移到工厂前后连接复用行为一致（对端若先于客户端关闭空闲连接，
  /// 保活越久越容易复用到已失效的连接）。
  static const Duration dioDefaultIdleTimeout = Duration(seconds: 3);

  /// 创建 [Dio]：保留调用方的 [BaseOptions]，底层 HttpClient 由 [createHttpClient] 提供，
  /// 其余 HttpClient 参数与 dio 默认适配器一致（见 [dioDefaultIdleTimeout]）。
  static Dio createDio(BaseOptions options, {String? Function()? proxy}) {
    final dio = Dio(options);
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () =>
          createHttpClient(idleTimeout: dioDefaultIdleTimeout, proxy: proxy),
    );
    return dio;
  }

  static Future<ConnectionTask<Socket>> _connect(
      Uri uri, String? proxyHost, int? proxyPort, SecurityContext? context) async {
    // 经代理：与 HttpClient 内建行为一致——明文连到代理，https 由 HttpClient 自行建隧道
    if (proxyHost != null) return Socket.startConnect(proxyHost, proxyPort!);

    final host = uri.host;
    final port = uri.port;
    final secure = uri.isScheme('https');
    final resolver = _resolver;
    // DoH 服务端自身的域名必须走系统 DNS 解析，否则会自己等自己
    if (resolver == null || resolver.endpoint.host == host) {
      // DoH 关闭：与 HttpClient 未设置 connectionFactory 时的内建路径相同
      return secure
          ? SecureSocket.startConnect(host, port, context: context)
          : Socket.startConnect(host, port);
    }

    final addresses = await resolver.lookup(host);
    return connectToAddresses(addresses, host: host, port: port, secure: secure, context: context);
  }

  /// 依次尝试地址建连；https 在 TCP 建立后以 [host] 升级 TLS（SNI + 证书主机名校验）。
  ///
  /// 证书校验失败（[HandshakeException]）立即抛出，不换下一个地址重试——
  /// 换 IP 不会让证书变合法，重试只会拖慢失败。
  static ConnectionTask<Socket> connectToAddresses(
    List<InternetAddress> addresses, {
    required String host,
    required int port,
    required bool secure,
    SecurityContext? context,
  }) {
    var cancelled = false;
    ConnectionTask<Socket>? current;

    Future<Socket> run() async {
      Object? lastError;
      for (final address in addresses) {
        if (cancelled) break;
        try {
          final task = await Socket.startConnect(address, port);
          current = task;
          final socket = await task.socket;
          if (!secure) return socket;
          return await SecureSocket.secure(socket, host: host, context: context);
        } on HandshakeException {
          rethrow;
        } on TlsException {
          rethrow;
        } catch (error) {
          lastError = error;
        }
      }
      if (cancelled) throw SocketException('连接已取消', osError: null, port: port);
      throw lastError ?? SocketException('没有可用地址：$host', port: port);
    }

    return ConnectionTask.fromSocket(run(), () {
      cancelled = true;
      current?.cancel();
    });
  }
}

class _DohHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) =>
        HttpClientFactory._connect(uri, proxyHost, proxyPort, context);
    return client;
  }
}
