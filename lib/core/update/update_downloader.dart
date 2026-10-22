import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';
import 'update_manifest.dart';
import 'update_mirrors.dart';

enum DownloadFailure {
  insecure,
  network,
  timeout,
  cancelled,
  diskFull,
  writeFailed,
  checksumMissing,
  checksumMismatch,
  notFound,
  server,
  badResponse,
}

class DownloadResult {
  final String? path;
  final String? sha256;
  final DownloadFailure? failure;
  final String? message;

  /// 实际使用的源标签（`直连 github.com` / `镜像 gh-proxy.com`）。
  /// 全部候选都失败时是最后一次尝试的源。
  final String? sourceLabel;

  /// 实际使用的镜像 id；直连时为 null。
  final String? mirrorId;

  const DownloadResult({
    this.path,
    this.sha256,
    this.failure,
    this.message,
    this.sourceLabel,
    this.mirrorId,
  });

  bool get ok => failure == null && path != null;

  DownloadResult withSource(DownloadCandidate candidate) => DownloadResult(
        path: path,
        sha256: sha256,
        failure: failure,
        message: message,
        sourceLabel: candidate.label,
        mirrorId: candidate.mirrorId,
      );
}

/// 下载安装包：断点续传 → 计算 SHA-256 → 校验通过才交出路径。
///
/// 安全约束：
/// - 只下载 https 资产；
/// - 没有可校验摘要时**直接失败**，绝不交出未校验文件；
/// - 落盘路径由本地拼装（`updates/<tag>/<basename>`），不接受远端给出的路径；
/// - 可经内置镜像下载，但**换源不降级校验**：镜像下完摘要不符时删文件并换下一个源。
class UpdateDownloader {
  final Dio _dio;
  final bool _ownsDio;
  final Future<Directory> Function() _dataDirectory;

  UpdateDownloader({
    Dio? dio,
    Future<Directory> Function()? dataDirectory,
  })  : _ownsDio = dio == null,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(minutes: 5),
            )),
        _dataDirectory =
            dataDirectory ?? WindowsConfigStorage().getStorageDirectory;

  void close() {
    if (_ownsDio) _dio.close(force: true);
  }

  Future<DownloadResult> download({
    required UpdateManifest manifest,
    required UpdateAsset asset,
    required CancelToken cancelToken,
    required void Function(int received, int total) onProgress,
    void Function()? onVerifying,
    List<DownloadCandidate>? candidates,
  }) async {
    final fileName = _safeSegment(p.basename(asset.name));
    if (fileName.isEmpty) {
      return const DownloadResult(
        failure: DownloadFailure.badResponse,
        message: '安装包名称无效',
      );
    }

    final list = _usableCandidates(asset, candidates);
    if (list.isEmpty) {
      return const DownloadResult(
        failure: DownloadFailure.insecure,
        message: '安装包地址不是 https，已取消下载',
      );
    }

    final expected = asset.sha256 ??
        await _checksumFromManifest(
          manifest,
          asset.name,
          cancelToken,
          useMirror: list.any((c) => c.viaMirror),
        );
    if (expected == null) {
      return const DownloadResult(
        failure: DownloadFailure.checksumMissing,
        message: '发布包缺少校验信息（digest 或 SHA256SUMS），已取消安装',
      );
    }

    final Directory directory;
    try {
      directory = Directory(p.join(
        (await _dataDirectory()).path,
        'updates',
        _safeSegment(manifest.tag),
      ));
      await directory.create(recursive: true);
      // 旧安装包会一直占 ~90 MB；顺手清掉 7 天前、非当前版本的残留
      await _pruneStaleDownloads(directory.parent, directory.path);
    } catch (error) {
      return DownloadResult(
        failure: _isDiskFull(error)
            ? DownloadFailure.diskFull
            : DownloadFailure.writeFailed,
        message: _writeMessage(error, asset.size),
      );
    }

    final target = File(p.join(directory.path, fileName));
    final part = File('${target.path}.part');

    DownloadResult? last;
    for (final candidate in list) {
      final outcome = await _downloadFrom(
        candidate: candidate,
        asset: asset,
        expected: expected,
        part: part,
        target: target,
        cancelToken: cancelToken,
        onProgress: onProgress,
        onVerifying: onVerifying,
      );
      if (outcome.ok) return outcome.withSource(candidate);
      // 与源无关的终态失败：换源没有意义，直接返回
      if (outcome.failure == DownloadFailure.cancelled ||
          outcome.failure == DownloadFailure.diskFull ||
          outcome.failure == DownloadFailure.writeFailed) {
        return outcome.withSource(candidate);
      }
      last = outcome.withSource(candidate);
    }
    return last ??
        const DownloadResult(
          failure: DownloadFailure.network,
          message: '下载失败，请重试',
        );
  }

  /// 只保留 https 候选；未显式给出候选时退回资产自身地址。
  static List<DownloadCandidate> _usableCandidates(
    UpdateAsset asset,
    List<DownloadCandidate>? provided,
  ) {
    final raw = provided == null || provided.isEmpty
        ? [DownloadCandidate(url: asset.url, label: '直连')]
        : provided;
    return raw
        .where((c) => Uri.tryParse(c.url)?.scheme == 'https')
        .toList(growable: false);
  }

  /// 从单个候选源下载并校验；跨源共用同一个 `.part`，实现续传。
  Future<DownloadResult> _downloadFrom({
    required DownloadCandidate candidate,
    required UpdateAsset asset,
    required String expected,
    required File part,
    required File target,
    required CancelToken cancelToken,
    required void Function(int received, int total) onProgress,
    void Function()? onVerifying,
  }) async {
    // 上一轮已经下完（或已改名为正式文件）但状态丢失：先校验，命中即完成
    if (!await part.exists() && await target.exists()) {
      final existing = await sha256OfFile(target);
      if (existing == expected) {
        return DownloadResult(path: target.path, sha256: existing);
      }
      try {
        await target.delete();
      } catch (_) {}
    }

    var start = await part.exists() ? await part.length() : 0;
    if (start > 0 && asset.size != null && start == asset.size) {
      final existing = await sha256OfFile(part);
      if (existing == expected) {
        await _promote(part, target);
        return DownloadResult(path: target.path, sha256: existing);
      }
      start = 0;
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      final (failure, restart) = await _transfer(
        url: candidate.url,
        asset: asset,
        part: part,
        start: start,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      if (failure != null) return failure;
      if (!restart) break;
      // 服务端要求从头下载（Range 失效）：清空后重试一次
      start = 0;
    }

    onVerifying?.call();
    final actual = await sha256OfFile(part);
    if (actual != expected) {
      try {
        await part.delete();
      } catch (_) {}
      return const DownloadResult(
        failure: DownloadFailure.checksumMismatch,
        message: '安装包校验失败（可能下载不完整），文件已删除，请重试',
      );
    }
    try {
      await _promote(part, target);
    } catch (error) {
      return DownloadResult(
        failure: _isDiskFull(error)
            ? DownloadFailure.diskFull
            : DownloadFailure.writeFailed,
        message: _writeMessage(error, asset.size),
      );
    }
    return DownloadResult(path: target.path, sha256: actual);
  }

  /// 返回 `(失败, 需要从头重下)`：失败为 null 且 restart=false 表示传输完成。
  Future<(DownloadResult?, bool)> _transfer({
    required String url,
    required UpdateAsset asset,
    required File part,
    required int start,
    required CancelToken cancelToken,
    required void Function(int received, int total) onProgress,
  }) async {
    Response<ResponseBody> response;
    try {
      response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          followRedirects: true,
          headers: {
            if (start > 0) 'Range': 'bytes=$start-',
          },
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      return (
        DownloadResult(
          failure: _mapDioFailure(error),
          message: _dioMessage(error),
        ),
        false
      );
    }

    final status = response.statusCode ?? 0;
    if (status == 416 && start > 0) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      return (null, true);
    }
    if (status == 404) {
      return (
        const DownloadResult(
          failure: DownloadFailure.notFound,
          message: '安装包不存在（404），请到发布页手动下载',
        ),
        false
      );
    }
    if (status != 200 && status != 206) {
      return (
        DownloadResult(
          failure: DownloadFailure.server,
          message: '下载失败（HTTP $status）',
        ),
        false
      );
    }

    final append = status == 206 && start > 0;
    final length =
        int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '');
    final total = append
        ? (length == null ? asset.size : start + length)
        : (length ?? asset.size);

    IOSink sink;
    try {
      sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
    } catch (error) {
      return (
        DownloadResult(
          failure: _isDiskFull(error)
              ? DownloadFailure.diskFull
              : DownloadFailure.writeFailed,
          message: _writeMessage(error, asset.size),
        ),
        false
      );
    }

    var written = append ? start : 0;
    try {
      await for (final chunk
          in response.data?.stream ?? const Stream<Uint8List>.empty()) {
        sink.add(chunk);
        written += chunk.length;
        onProgress(written, total ?? written);
      }
      await sink.flush();
      await sink.close();
    } catch (error) {
      try {
        await sink.close();
      } catch (_) {}
      if (_isDiskFull(error)) {
        return (
          DownloadResult(
            failure: DownloadFailure.diskFull,
            message: _writeMessage(error, asset.size),
          ),
          false
        );
      }
      if (error is DioException) {
        return (
          DownloadResult(
            failure: _mapDioFailure(error),
            message: _dioMessage(error),
          ),
          false
        );
      }
      return (
        DownloadResult(
          failure: DownloadFailure.writeFailed,
          message: _writeMessage(error, asset.size),
        ),
        false
      );
    }
    return (null, false);
  }

  /// 从同源 `SHA256SUMS` 里取目标文件的摘要；没有则返回 null。
  ///
  /// 资产直连不可达时，`SHA256SUMS` 同样可能拿不到，因此允许经镜像再试一次。
  Future<String?> _checksumFromManifest(
    UpdateManifest manifest,
    String assetName,
    CancelToken cancelToken, {
    bool useMirror = false,
  }) async {
    final sums = manifest.checksums;
    if (sums == null || !sums.isHttps) return null;
    final urls = <String>[sums.url];
    if (useMirror) {
      for (final mirror in kBuiltinMirrors) {
        final resolved = mirror.resolve(sums.url);
        if (resolved != null && !urls.contains(resolved)) urls.add(resolved);
      }
    }
    for (final url in urls) {
      final digest = await _readSums(url, assetName, cancelToken);
      if (digest != null) return digest;
    }
    return null;
  }

  Future<String?> _readSums(
    String url,
    String assetName,
    CancelToken cancelToken,
  ) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
      if (response.statusCode != 200) return null;
      for (final line in const LineSplitter().convert(response.data ?? '')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final match =
            RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(trimmed);
        if (match == null) continue;
        if (p.basename(match.group(2)!.trim()) == assetName) {
          return match.group(1)!.toLowerCase();
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<void> _promote(File part, File target) async {
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  }

  /// 清理 `updates/` 下非当前版本、超过 7 天的安装包与临时文件。
  Future<void> _pruneStaleDownloads(Directory root, String keepPath) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory || entity.path == keepPath) continue;
        await for (final child in entity.list(followLinks: false)) {
          if (child is! File) continue;
          final name = p.basename(child.path);
          if (!name.endsWith('.exe') && !name.endsWith('.part')) continue;
          try {
            final modified = (await child.stat()).modified;
            if (modified.isBefore(cutoff)) await child.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      // 清理失败不影响下载
    }
  }

  static String _safeSegment(String raw) =>
      raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  static bool _isDiskFull(Object error) {
    if (error is! FileSystemException) return false;
    final code = error.osError?.errorCode;
    return code == 112 || code == 28;
  }

  static String _writeMessage(Object error, int? size) {
    if (_isDiskFull(error)) {
      final need = size == null
          ? ''
          : '（需约 ${(size / (1024 * 1024)).toStringAsFixed(1)} MB）';
      return '磁盘空间不足$need';
    }
    if (error is FileSystemException) {
      return '写入安装包失败：${error.osError?.message ?? error.message}';
    }
    return '写入安装包失败';
  }

  static DownloadFailure _mapDioFailure(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return DownloadFailure.timeout;
      case DioExceptionType.cancel:
        return DownloadFailure.cancelled;
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return DownloadFailure.network;
      case DioExceptionType.badResponse:
        return DownloadFailure.server;
    }
  }

  static String _dioMessage(DioException error) {
    switch (_mapDioFailure(error)) {
      case DownloadFailure.cancelled:
        return '下载已取消';
      case DownloadFailure.timeout:
        return '下载超时，可重试续传';
      case DownloadFailure.network:
        return '网络中断，已保留进度，可继续下载';
      default:
        return '下载失败（HTTP ${error.response?.statusCode ?? '-'}）';
    }
  }
}

/// 分块计算文件 SHA-256（不把整个安装包读进内存）。
Future<String> sha256OfFile(File file) async {
  final sink = _SingleDigestSink();
  final input = sha256.startChunkedConversion(sink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return sink.digest?.toString() ?? '';
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}
