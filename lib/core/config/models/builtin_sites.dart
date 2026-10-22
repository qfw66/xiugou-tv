import 'vod_config.dart';

/// 内置虚拟站点（不来自用户配置）。
///
/// 目前只有「豆瓣热播」（backlog §17）：它只承担**导航**——首页展示豆瓣分类
/// 与影片，点片拿片名去做全局搜索；它没有可执行的请求端点，因此：
/// - 不进 `VodConfig.sites`（不影响配置、聚合搜索、站源体检）；
/// - 由 `ConfigRepository.homeSiteChoices` / 站源切换弹窗把它拼在列表首位。
const Site builtinDoubanSite = Site(
  key: 'builtin://douban',
  name: '豆瓣热播',
  api: 'builtin://douban',
);

/// 是否为内置虚拟站（`builtin://` 前缀）。
bool isBuiltinSite(Site site) => site.key.startsWith('builtin://');
