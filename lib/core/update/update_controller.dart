import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app_info.dart';
import 'installer_launcher.dart';
import 'update_downloader.dart';
import 'update_mirror_health.dart';
import 'update_mirror_catalog.dart';
import 'update_mirrors.dart';
import 'update_preferences.dart';
import 'update_preferences_notifier.dart';
import 'update_service.dart';

enum UpdatePhase {
  /// 没有进行中的操作（可能已拿到检查结果）
  idle,
  checking,
  downloading,
  verifying,

  /// 已校验通过，等待用户确认安装
  ready,
}

class UpdateUiState {
  final UpdatePhase phase;
  final UpdateCheckResult? result;
  final int received;
  final int total;
  final String? downloadError;
  final String? downloadedPath;

  const UpdateUiState({
    this.phase = UpdatePhase.idle,
    this.result,
    this.received = 0,
    this.total = 0,
    this.downloadError,
    this.downloadedPath,
  });

  double get progress =>
      total <= 0 ? 0 : (received / total).clamp(0.0, 1.0).toDouble();

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.verifying;
}

/// 更新流程状态机：检查 → 下载 → 校验 → 安装。
///
/// 单任务互斥：检查与下载不会同时进行；对话框关闭不影响已开始的下载，
/// 但用户可以显式取消（保留 `.part` 供下次续传）。
class UpdateController extends StateNotifier<UpdateUiState> {
  final UpdateService _service;
  final UpdateDownloader _downloader;
  final InstallerLauncher _launcher;
  final UpdatePreferencesNotifier _preferences;
  final UpdateMirrorHealthStore _mirrorHealth;
  final UpdateMirrorCatalog _mirrorCatalog;
  final bool _ownsMirrorCatalog;
  CancelToken? _checkToken;
  final Future<void> Function() _closeApp;
  final String? Function() _versionLabel;
  final Future<void> Function() _beforeInstall;

  CancelToken? _downloadToken;
  bool _checking = false;

  UpdateController({
    required UpdateService service,
    required UpdateDownloader downloader,
    required InstallerLauncher launcher,
    required UpdatePreferencesNotifier preferences,
    required Future<void> Function() closeApp,
    String? Function()? versionLabel,
    Future<void> Function()? beforeInstall,
    UpdateMirrorHealthStore? mirrorHealth,
    UpdateMirrorCatalog? mirrorCatalog,
  })  : _service = service,
        _downloader = downloader,
        _launcher = launcher,
        _preferences = preferences,
        _mirrorHealth = mirrorHealth ?? UpdateMirrorHealthStore(),
        _mirrorCatalog = mirrorCatalog ?? UpdateMirrorCatalog(),
        _ownsMirrorCatalog = mirrorCatalog == null,
        _closeApp = closeApp,
        _versionLabel = versionLabel ?? (() => appVersionLabel),
        _beforeInstall = beforeInstall ?? _defaultBeforeInstall,
        super(const UpdateUiState());

  static Future<void> _defaultBeforeInstall() =>
      Future<void>.delayed(const Duration(milliseconds: 1200));

  bool get isPortable => !_launcher.isInstalledBuild;

  // Only routing changes invalidate work already requested by the user.
  // Auto-check and skipped-version preferences do not alter its transport.
  bool _hasCurrentRouting(UpdatePreferences captured) {
    final current = _preferences.state;
    return current.source == captured.source &&
        current.useMirror == captured.useMirror &&
        current.mirrorsUrl == captured.mirrorsUrl;
  }

  Future<UpdateCheckResult?> check() async {
    if (_checking || state.busy) return null;
    _checking = true;
    final token = CancelToken();
    _checkToken = token;
    final preferences = _preferences.state;
    state = UpdateUiState(phase: UpdatePhase.checking, result: state.result);
    try {
      final mirrors = await _mirrorCatalog.resolve(
        endpoint: preferences.mirrorsUrl,
        enabled: preferences.useMirror,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled || !_hasCurrentRouting(preferences)) {
        return null;
      }
      final health = await _mirrorHealth.load();
      if (!mounted || token.isCancelled || !_hasCurrentRouting(preferences)) {
        return null;
      }
      final result = await _service.check(
        localVersion: _versionLabel() ?? '',
        preferences: preferences,
        cancelToken: token,
        mirrors: mirrors,
        coolingDownMirrors: health.coolingDownIds(),
        onMirrorResult: _recordMirrorCheck,
      );
      if (!mounted || token.isCancelled || !_hasCurrentRouting(preferences)) {
        return null;
      }
      state = UpdateUiState(phase: UpdatePhase.idle, result: result);
      return result;
    } on DioException catch (error) {
      if (!CancelToken.isCancel(error)) rethrow;
      return null;
    } finally {
      _checking = false;
      if (_checkToken == token) {
        _checkToken = null;
        if (mounted && state.phase == UpdatePhase.checking) {
          state = UpdateUiState(phase: UpdatePhase.idle, result: state.result);
        }
      }
    }
  }

  /// 镜像探测结果落盘（尽力而为，不阻断检查）。
  void _recordMirrorCheck(String mirrorId, bool success) {
    unawaited(success
        ? _mirrorHealth.recordCheckSuccess(mirrorId)
        : _mirrorHealth.recordCheckFailure(mirrorId));
  }

  Future<void> downloadAndInstall() async {
    final result = state.result;
    final manifest = result?.manifest;
    final asset = result?.installer;
    if (manifest == null || asset == null) return;
    if (state.busy) return;

    final preferences = _preferences.state;
    final token = CancelToken();
    _downloadToken = token;
    state = UpdateUiState(phase: UpdatePhase.downloading, result: result);

    void onProgress(int received, int total) {
      if (!mounted || _downloadToken != token) return;
      if (state.phase == UpdatePhase.verifying) return;
      state = UpdateUiState(
        phase: UpdatePhase.downloading,
        result: result,
        received: received,
        total: total,
      );
    }

    void onVerifying() {
      if (!mounted || _downloadToken != token) return;
      state = UpdateUiState(
        phase: UpdatePhase.verifying,
        result: result,
        received: asset.size ?? state.received,
        total: asset.size ?? state.total,
      );
    }

    bool isCurrent() =>
        mounted &&
        _downloadToken == token &&
        !token.isCancelled &&
        _hasCurrentRouting(preferences);
    late final List<UpdateMirror> mirrors;
    try {
      mirrors = await _mirrorCatalog.resolve(
        endpoint: preferences.mirrorsUrl,
        enabled: preferences.useMirror,
        cancelToken: token,
      );
    } on DioException catch (error) {
      if (!CancelToken.isCancel(error)) rethrow;
      if (mounted && _downloadToken == token) cancelDownload();
      return;
    }
    if (!isCurrent()) {
      if (mounted && _downloadToken == token) cancelDownload();
      return;
    }
    final health = await _mirrorHealth.load();
    if (!isCurrent()) {
      if (mounted && _downloadToken == token) cancelDownload();
      return;
    }
    final outcome = await _downloader.download(
      manifest: manifest,
      asset: asset,
      cancelToken: token,
      onProgress: onProgress,
      onVerifying: onVerifying,
      mirrors: mirrors,
      candidates: downloadCandidates(
        assetUrl: asset.url,
        useMirror: preferences.useMirror,
        mirrors: mirrors,
        lastGoodMirrorId: health.lastGoodDownloadSource,
        coolingDown: health.coolingDownIds(),
      ),
    );

    if (!mounted || _downloadToken != token) return;
    if (!_hasCurrentRouting(preferences)) {
      cancelDownload();
      return;
    }
    _downloadToken = null;

    if (outcome.ok) {
      unawaited(_mirrorHealth.recordDownloadSuccess(outcome.mirrorId));
    } else if (outcome.failure != DownloadFailure.cancelled &&
        outcome.mirrorId != null) {
      unawaited(_mirrorHealth.recordDownloadFailure(outcome.mirrorId!));
    }

    if (outcome.ok) {
      state = UpdateUiState(
        phase: UpdatePhase.ready,
        result: result,
        received: asset.size ?? state.received,
        total: asset.size ?? state.total,
        downloadedPath: outcome.path,
      );
      return;
    }
    if (outcome.failure == DownloadFailure.cancelled) {
      state = UpdateUiState(phase: UpdatePhase.idle, result: result);
      return;
    }
    state = UpdateUiState(
      phase: UpdatePhase.idle,
      result: result,
      downloadError: outcome.message ?? '下载失败，请重试',
    );
  }

  void cancelDownload() {
    final token = _downloadToken;
    _downloadToken = null;
    token?.cancel('用户取消');
    if (!mounted) return;
    if (state.phase == UpdatePhase.downloading ||
        state.phase == UpdatePhase.verifying) {
      state = UpdateUiState(phase: UpdatePhase.idle, result: state.result);
    }
  }

  Future<void> install() async {
    final path = state.downloadedPath;
    if (path == null) return;
    final launched = await _launcher.launch(path);
    if (!mounted) return;
    if (!launched) {
      state = UpdateUiState(
        phase: UpdatePhase.ready,
        result: state.result,
        received: state.received,
        total: state.total,
        downloadedPath: path,
        downloadError: '无法启动安装程序，请打开所在文件夹手动运行',
      );
      return;
    }
    await _beforeInstall();
    await _closeApp();
  }

  Future<void> skipCurrentVersion() async {
    final tag = state.result?.manifest?.tag;
    if (tag == null) return;
    await _preferences.skipVersion(tag);
  }

  Future<void> clearSkipped() => _preferences.clearSkipped();

  Future<void> openReleasePage() async {
    await _launcher.openUrl(releasePageUrl);
  }

  Future<void> openDownloadFolder() async {
    final path = state.downloadedPath;
    if (path == null) return;
    await _launcher.openFolder(p.dirname(path));
  }

  @override
  void dispose() {
    _checkToken?.cancel('控制器销毁');
    _downloadToken?.cancel('控制器销毁');
    if (_ownsMirrorCatalog) _mirrorCatalog.dispose();
    super.dispose();
  }
}
