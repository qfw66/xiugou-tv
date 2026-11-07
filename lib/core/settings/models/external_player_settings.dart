/// 外部播放器的参数协议；通用模式仅传递播放地址。
enum ExternalPlayerKind { generic, mpv, vlc }

class ExternalPlayerSettings {
  static const ExternalPlayerSettings defaults = ExternalPlayerSettings();

  final String executablePath;
  final ExternalPlayerKind kind;

  const ExternalPlayerSettings({
    this.executablePath = '',
    this.kind = ExternalPlayerKind.generic,
  });

  /// 仅表示已填写路径；路径合法性与文件存在性由启动器检查。
  bool get isConfigured => executablePath.trim().isNotEmpty;

  ExternalPlayerSettings copyWith({
    String? executablePath,
    ExternalPlayerKind? kind,
  }) =>
      ExternalPlayerSettings(
        executablePath: executablePath ?? this.executablePath,
        kind: kind ?? this.kind,
      );

  /// 兼容旧设置中缺失的字段；非法类型与未知协议分别回退到默认值。
  factory ExternalPlayerSettings.fromJson(Object? json) {
    if (json is! Map) return defaults;
    final path = json['executablePath'];
    return ExternalPlayerSettings(
      executablePath: path is String ? path : '',
      kind: switch (json['kind']) {
        'mpv' => ExternalPlayerKind.mpv,
        'vlc' => ExternalPlayerKind.vlc,
        _ => ExternalPlayerKind.generic,
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'executablePath': executablePath,
        'kind': kind.name,
      };

  @override
  bool operator ==(Object other) =>
      other is ExternalPlayerSettings &&
      other.executablePath == executablePath &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(executablePath, kind);
}
