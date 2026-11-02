import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import '../diagnostics/error_log.dart';

/// 系统 DNS 查询（可注入以便测试）
typedef SystemLookup = Future<List<InternetAddress>> Function(String host);

/// DoH 查询的底层传输：给定完整请求 URL，返回 `application/dns-message` 报文。
typedef DohTransport = Future<Uint8List> Function(Uri url);

/// 安全 DNS（DNS over HTTPS，RFC 8484）解析器（§14）。
///
/// - 并行查 A / AAAA，IPv4 在前；结果按记录 TTL 缓存（夹在 [minTtl]..[maxTtl]）；
/// - 同一主机的并发查询合并为一次；
/// - DoH 失败（超时 / HTTP 错误 / 报文异常 / 无记录）时**回落系统 DNS**并写诊断日志，
///   保证选错服务或服务不可达时不会断网；回落结果不进缓存，下次仍先试 DoH；
/// - IP 字面量与 `localhost` 不查 DoH（本机 Companion 等直连地址）。
///
/// DoH 请求本身走独立的 [HttpClient]（系统 DNS 解析 DoH 服务器域名，证书照常校验），
/// 避免「解析 DoH 服务器也要先 DoH」的自举死循环。
class DohResolver {
  DohResolver({
    required this.endpoint,
    DohTransport? transport,
    SystemLookup? systemLookup,
    DateTime Function()? clock,
    void Function(String message)? log,
    this.timeout = const Duration(seconds: 5),
    this.minTtl = const Duration(seconds: 30),
    this.maxTtl = const Duration(hours: 1),
    this.failureBackoff = const Duration(minutes: 1),
  })  : _transport = transport ?? _HttpDohTransport(timeout).call,
        _systemLookup = systemLookup ?? InternetAddress.lookup,
        _clock = clock ?? DateTime.now,
        _log = log ?? _defaultLog;

  final Uri endpoint;
  final Duration timeout;
  final Duration minTtl;
  final Duration maxTtl;

  /// 某主机 DoH 失败后，这段时间内直接走系统 DNS（不反复请求、不刷屏日志）
  final Duration failureBackoff;

  final DohTransport _transport;
  final SystemLookup _systemLookup;
  final DateTime Function() _clock;
  final void Function(String message) _log;

  final _cache = <String, _CacheEntry>{};
  final _pending = <String, Future<List<InternetAddress>>>{};
  final _failedUntil = <String, DateTime>{};

  /// 诊断日志：开发日志 + 「关于 → 错误日志」（仅内存，便于用户反馈时查看）
  static void _defaultLog(String message) {
    developer.log(message, name: 'xiugou-tv::doh');
    ErrorLog.instance.record('安全 DNS', message);
  }

  /// 解析主机名；返回非空地址列表，系统 DNS 也失败时抛 [SocketException]。
  Future<List<InternetAddress>> lookup(String host) {
    final key = host.toLowerCase();
    final literal = InternetAddress.tryParse(key);
    if (literal != null) return Future.value([literal]);
    if (key == 'localhost' || !_isAsciiHost(key)) return _systemLookup(host);

    final cached = _cache[key];
    if (cached != null) {
      if (_clock().isBefore(cached.expiresAt)) return Future.value(cached.addresses);
      _cache.remove(key);
    }
    final failedUntil = _failedUntil[key];
    if (failedUntil != null) {
      if (_clock().isBefore(failedUntil)) return _systemLookup(host);
      _failedUntil.remove(key);
    }
    return _pending[key] ??= _resolve(key).whenComplete(() {
      // 块体：箭头函数会把被移除的 Future 本身返回给 whenComplete，形成自等待
      _pending.remove(key);
    });
  }

  /// 清空缓存（切换 DoH 服务时由工厂丢弃整个解析器，一般无需调用）。
  void clearCache() => _cache.clear();

  Future<List<InternetAddress>> _resolve(String host) async {
    try {
      // 单个类型失败（如服务对 AAAA 报错）不影响另一类型；两者都拿不到地址才回落。
      Object? firstError;
      Future<_Answer> attempt(int type) => _query(host, type).catchError((Object e) {
            firstError ??= e;
            return const _Answer([], Duration.zero);
          });
      final results = await Future.wait([attempt(_typeA), attempt(_typeAaaa)]).timeout(timeout);
      final answered = results.where((r) => r.addresses.isNotEmpty).toList();
      if (answered.isEmpty) throw firstError ?? const FormatException('DoH 未返回地址记录');
      final addresses = [for (final r in answered) ...r.addresses];
      final ttls = [for (final r in answered) r.ttl];
      var ttl = ttls.reduce((a, b) => a < b ? a : b);
      if (ttl < minTtl) ttl = minTtl;
      if (ttl > maxTtl) ttl = maxTtl;
      _cache[host] = _CacheEntry(List.unmodifiable(addresses), _clock().add(ttl));
      return addresses;
    } catch (error) {
      _failedUntil[host] = _clock().add(failureBackoff);
      _log('DoH 解析 $host 失败（${endpoint.host}）：$error；回落系统 DNS');
      return _systemLookup(host);
    }
  }

  Future<_Answer> _query(String host, int type) async {
    final message = encodeQuery(host, type);
    final dns = base64Url.encode(message).replaceAll('=', '');
    final url = endpoint.replace(queryParameters: {
      ...endpoint.queryParameters,
      'dns': dns,
    });
    final body = await _transport(url);
    return _Answer.parse(body, type);
  }

  static const int _typeA = 1;
  static const int _typeAaaa = 28;

  static bool _isAsciiHost(String host) =>
      host.isNotEmpty && host.codeUnits.every((c) => c > 0x20 && c < 0x7f);

  /// 组 RFC 1035 查询报文（ID 固定 0，便于 HTTP 缓存，RFC 8484 §4.1 建议）。
  static Uint8List encodeQuery(String host, int type) {
    final builder = BytesBuilder();
    builder.add(const [0, 0, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in host.split('.')) {
      if (label.isEmpty) continue;
      final bytes = ascii.encode(label);
      if (bytes.length > 63) throw FormatException('域名标签过长：$label');
      builder.addByte(bytes.length);
      builder.add(bytes);
    }
    builder.addByte(0);
    builder.add([type >> 8, type & 0xff, 0, 1]);
    return builder.toBytes();
  }
}

class _CacheEntry {
  final List<InternetAddress> addresses;
  final DateTime expiresAt;

  const _CacheEntry(this.addresses, this.expiresAt);
}

/// 解析后的单类型应答：地址 + 最小 TTL
class _Answer {
  final List<InternetAddress> addresses;
  final Duration ttl;

  const _Answer(this.addresses, this.ttl);

  static _Answer parse(Uint8List data, int wantType) {
    if (data.length < 12) throw const FormatException('DNS 应答过短');
    final view = ByteData.sublistView(data);
    final flags = view.getUint16(2);
    if (flags & 0x8000 == 0) throw const FormatException('不是 DNS 应答');
    final rcode = flags & 0x000f;
    // NXDOMAIN 等：视为该类型无记录，由上层决定是否回落
    if (rcode != 0) return const _Answer([], Duration.zero);
    final qdCount = view.getUint16(4);
    final anCount = view.getUint16(6);
    var offset = 12;
    for (var i = 0; i < qdCount; i++) {
      offset = _skipName(data, offset) + 4;
    }
    final addresses = <InternetAddress>[];
    int? minTtl;
    for (var i = 0; i < anCount; i++) {
      offset = _skipName(data, offset);
      if (offset + 10 > data.length) throw const FormatException('DNS 应答截断');
      final type = view.getUint16(offset);
      final ttl = view.getUint32(offset + 4);
      final length = view.getUint16(offset + 8);
      offset += 10;
      if (offset + length > data.length) throw const FormatException('DNS 应答截断');
      final expected = wantType == 1 ? 4 : 16;
      // CNAME 等其他记录跳过：DoH 服务会把链路终点的 A / AAAA 一并放进应答
      if (type == wantType && length == expected) {
        addresses.add(InternetAddress.fromRawAddress(
            Uint8List.fromList(data.sublist(offset, offset + length))));
        if (minTtl == null || ttl < minTtl) minTtl = ttl;
      }
      offset += length;
    }
    return _Answer(addresses, Duration(seconds: minTtl ?? 0));
  }

  /// 跳过一个（可能压缩的）域名，返回其后的偏移
  static int _skipName(Uint8List data, int offset) {
    while (true) {
      if (offset >= data.length) throw const FormatException('DNS 应答截断');
      final length = data[offset];
      if (length == 0) return offset + 1;
      if (length & 0xc0 == 0xc0) return offset + 2;
      offset += length + 1;
    }
  }
}

/// 默认传输：RFC 8484 GET，独立 HttpClient（系统 DNS、标准证书校验）。
class _HttpDohTransport {
  _HttpDohTransport(this.timeout);

  final Duration timeout;
  late final HttpClient _client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = 'xiugou-tv';

  /// DNS 报文上限 64 KB，超过即视为异常
  static const int _maxBytes = 65535;

  Future<Uint8List> call(Uri url) async {
    final request = await _client.getUrl(url).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/dns-message');
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('DoH 服务返回 HTTP ${response.statusCode}', uri: url);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > _maxBytes) throw const FormatException('DoH 应答过大');
    }
    return builder.takeBytes();
  }
}
