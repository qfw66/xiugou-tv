import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app_info.dart';
import 'installer_launcher.dart';
import 'update_downloader.dart';
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
  })  : _service = service,
        _downloader = downloader,
        _launcher = launcher,
        _preferences = preferences,
        _closeApp = closeApp,
        _versionLabel = versionLabel ?? (() => appVersionLabel),
        _beforeInstall = beforeInstall ?? _defaultBeforeInstall,
        super(const UpdateUiState());

  static Future<void> _defaultBeforeInstall() =>
      Future<void>.delayed(const Duration(milliseconds: 1200));

  bool get isPortable => !_launcher.isInstalledBuild;

  Future<UpdateCheckResult?> check() async {
    if (_checking) return null;
    _checking = true;
    state = UpdateUiState(phase: UpdatePhase.checking, result: state.result);
    try {
      final result = await _service.check(
        localVersion: _versionLabel() ?? '',
        preferences: _preferences.state,
      );
      if (!mounted) return null;
      state = UpdateUiState(phase: UpdatePhase.idle, result: result);
      return result;
    } finally {
      _checking = false;
    }
  }

  Future<void> downloadAndInstall() async {
    final result = state.result;
    final manifest = result?.manifest;
    final asset = result?.installer;
    if (manifest == null || asset == null) return;
    if (state.phase == UpdatePhase.downloading ||
        state.phase == UpdatePhase.verifying) {
      return;
    }

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

    final outcome = await _downloader.download(
      manifest: manifest,
      asset: asset,
      cancelToken: token,
      onProgress: onProgress,
      onVerifying: onVerifying,
    );

    if (!mounted || _downloadToken != token) return;
    _downloadToken = null;

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
    _downloadToken?.cancel('控制器销毁');
    super.dispose();
  }
}
