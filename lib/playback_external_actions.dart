part of 'app.dart';

final externalPlayerLauncherProvider =
    Provider<ExternalPlayerLauncher>((ref) => ExternalPlayerLauncher());

typedef PlaybackExternalConfirmation = Future<bool> Function(
    List<String> warnings);

final launchExternalPlaybackProvider =
    Provider<Future<void> Function(PlaybackExternalConfirmation)>(
        (ref) => (confirm) => _launchExternalPlayback(ref, confirm));

Future<void> _launchExternalPlayback(
    Ref ref, PlaybackExternalConfirmation confirm) async {
  final spec = ref.read(activePlaySpecProvider);
  if (spec == null ||
      _sourceChangeBlocked(ref) ||
      ref.read(playbackIntentProvider) != null) {
    return;
  }
  final playerSettings = ref.read(settingsRepositoryProvider).playerSettings;
  final settings = playerSettings.externalPlayer;
  final launchSpec = spec.copyWith(
      headers: withBrowserHeaderFallbacks(
    spec.headers,
    spec.url,
    enabled: playerSettings.browserHeaders,
  ));
  if (!settings.isConfigured) {
    ref.read(settingsPageOpenProvider.notifier).state = true;
    ref.read(lineSwitchNoticeProvider.notifier).state =
        '请在「播放设置 → 第三方播放器」中选择播放器程序';
    return;
  }
  final owner = _SourceChangeOwner(ref, PlaybackSourceChangeKind.external);
  final engine = ref.read(playerEngineProvider);
  final engineSpec = engine.currentSpec;
  final launcher = ref.read(externalPlayerLauncherProvider);
  var handedOff = false;
  bool isCurrent() =>
      owner.isCurrent &&
      identical(ref.read(activePlaySpecProvider), spec) &&
      identical(engine.currentSpec, engineSpec) &&
      ref.read(settingsRepositoryProvider).playerSettings.externalPlayer ==
          settings &&
      ref.read(settingsRepositoryProvider).playerSettings.browserHeaders ==
          playerSettings.browserHeaders;
  try {
    owner.status('正在准备外部播放器…');
    var plan = launcher.buildPlan(
        settings: settings, spec: launchSpec, position: engine.position);
    if (plan.warnings.isNotEmpty) {
      owner.status('等待确认外部播放器…');
      final accepted = await owner.wait(confirm(plan.warnings));
      if (!accepted || !isCurrent()) return;
      // The internal video keeps playing while the confirmation is open.
      plan = launcher.buildPlan(
          settings: settings, spec: launchSpec, position: engine.position);
    }
    if (!isCurrent()) return;
    owner.status('正在启动外部播放器…');
    final started =
        await owner.wait(launcher.launch(plan, isCurrent: isCurrent));
    if (!started || !isCurrent()) return;
    handedOff = true;
    ref.read(autoLineSwitchProvider).disarm();
    try {
      await owner.wait(engine.runtimeType == MpvPlayerEngine
          ? engine.pauseForExternalPlayback()
          : engine.pause());
      if (!isCurrent()) return;
      await owner.wait(ref.read(playbackHistoryTrackerProvider).flush());
      if (!isCurrent()) return;
      ref.read(lineSwitchNoticeProvider.notifier).state =
          '已启动外部播放器，内置播放已暂停；外部播放进度不会回传';
    } catch (_) {
      if (isCurrent()) {
        ref.read(lineSwitchNoticeProvider.notifier).state =
            '已启动外部播放器，请手动暂停内置播放';
      }
    }
  } on PlaybackSourceCancelled {
    // Cancellation must not act on a newer playback or its notices.
  } on ExternalPlayerLaunchException catch (error) {
    if (isCurrent()) {
      ref.read(lineSwitchNoticeProvider.notifier).state = error.message;
    }
  } catch (_) {
    if (isCurrent()) {
      ref.read(lineSwitchNoticeProvider.notifier).state =
          '无法启动外部播放器，请检查播放设置中的程序路径';
    }
  } finally {
    owner.dispose(rearm: !handedOff);
  }
}

Future<bool> _confirmExternalPlayback(
    BuildContext context, WidgetRef ref, List<String> warnings) async {
  final token = ref.read(playbackSourceChangeProvider)?.cancelToken;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('使用外部播放器'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Text('${warnings.join('\n\n')}\n\n是否继续打开？'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('继续打开'),
        ),
      ],
    ),
  );
  token?.onCancel(() {
    if (route.isActive) navigator.removeRoute(route);
  });
  return await navigator.push(route) ?? false;
}
