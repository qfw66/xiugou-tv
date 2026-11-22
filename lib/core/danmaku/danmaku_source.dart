/// 内置弹幕接口的稳定标识。私有地址由构建配置提供，不写入用户设置。
enum DanmakuSource {
  primary('primary', '默认接口'),
  secondary('overide', '备用接口（Overide）');

  const DanmakuSource(this.id, this.label);

  final String id;
  final String label;

  static DanmakuSource fromJson(Object? value) =>
      values.firstWhere((source) => source.id == value, orElse: () => primary);
}
