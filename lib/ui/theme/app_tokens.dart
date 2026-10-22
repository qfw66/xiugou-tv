/// 界面几何 / 节奏 / 字级令牌（backlog §1 · B1）。
///
/// 为什么需要它：B1 之前，界面里有 **12 种圆角、8 种动效时长、14 种字号**——
/// 每加一个页面就多一种写法（skill 规则 `spacing-scale` / `font-scale` /
/// `elevation-consistent` 都要求成档）。这里把它们收成一小组语义档位，
/// 页面只引用档位，不再写裸数值。
///
/// 方向：**D2 影音沉浸感**（你 2026-10-19 选定）——圆角偏大、卡片有存在感、
/// hover 有轻放大与柔光、动效「进 200ms / 出 140ms」。
///
/// 另见 `docs/UI_POLISH_PLAN.md` §4–§5。
library;

import 'package:flutter/material.dart';

/// 圆角档位。
///
/// 取代原先的 `2 / 4 / 6 / 7 / 8 / 10 / 12 / 14 / 16 / 18 / 32 / 999` 共 12 种取值。
/// 归并时把 `6 / 7` 提到 `sm`（8）、把 `10` 提到 `md`（12）、把 `14 / 18` 提到 `lg`（16）——
/// D2 的取向是卡片更圆更有存在感，故取"向上取整"。
abstract final class AppRadii {
  /// 细进度条（3–4px 高）
  static const double hairline = 2;

  /// 角标 / 小标签
  static const double xs = 4;

  /// 胶囊按钮、图标按钮、输入框
  static const double sm = 8;

  /// 列表行、面板、小容器
  static const double md = 12;

  /// 卡片、弹窗、海报
  static const double lg = 16;

  /// 全圆（圆形头像 / 胶囊）
  static const double pill = 999;
}

/// 间距档位（4 的倍数）。
///
/// 现状里 `4 / 6 / 8 / 10 / 12 / 14 / 16 / 20 / 24` 混用；B1 只把新代码与新页面
/// 引到这些档位上，历史逐处替换放到各批次里顺手做（避免一次性大范围位移）。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// 动效节奏（D2：进 200ms / 出 140ms）。
///
/// skill 的 `exit-faster-than-enter`（退出要快于进入才跟手）与 `motion-consistency`
/// （全局共用一个节奏）是这两档的来源；hover 变色这类"单值"场景统一用 [base]。
abstract final class AppMotion {
  /// 进入 / 展开 / 悬停高亮
  static const Duration enter = Duration(milliseconds: 200);

  /// 退出 / 收起
  static const Duration exit = Duration(milliseconds: 140);

  /// 单值场景（一个 duration 同时管进出的 hover 变色等）
  static const Duration base = enter;

  /// 大位移（页面级过渡、抽屉），B2 之后才会用到
  static const Duration slow = Duration(milliseconds: 240);

  /// Hero 大屏交叉淡入（比常规进入更长，避免切换时"闪一下"）
  static const Duration heroFade = Duration(milliseconds: 600);

  /// 横向画报轨道翻页滑动
  static const Duration rowScroll = Duration(milliseconds: 350);

  /// 默认缓动：减速到达，符合"到达感"
  static const Curve ease = Curves.easeOutCubic;
}

/// 字号档位（7 档）。
///
/// 取代原先的 `10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13 / 13.5 / 14 / 15 / 16 / 17 / 18 / 20`
/// 共 14 种取值。归并规则：`10 / 10.5 → caption`、`11.5 → body`、`12.5 → label`、
/// `13.5 → title`、`15 / 16 → heading`、`17 / 18 → h2`。
abstract final class AppType {
  /// 角标、弱提示
  static const double caption = 11;

  /// 正文（用得最多）
  static const double body = 12;

  /// 强调正文 / 按钮文字
  static const double label = 13;

  /// 列表标题、卡片标题
  static const double title = 14;

  /// 分区标题
  static const double heading = 16;

  /// 弹窗 / 面板标题
  static const double h2 = 18;

  /// 页面标题
  static const double h1 = 20;

  /// 极微字：海报角标 / 评分胶囊（再小就看不清了）
  static const double micro = 10;

  /// 大屏主按钮文字（介于正文与分区标题之间）
  static const double lead = 15;

  /// 巨幅标题：Hero 大屏片名，只用于沉浸大屏
  static const double display = 38;
}

/// 键盘焦点环（skill 规则 `focus-states` 属 CRITICAL：焦点必须可见）。
///
/// 颜色取当前主题的 `AppPalette.accentInk`，绘制由 `FocusRing` 组件负责。
abstract final class AppFocus {
  /// 环宽（2px 是 skill 给出的下限区间 2–4 之内）
  static const double ringWidth = 2;

  /// 环与控件边缘的间距
  static const double ringOffset = 2;
}

/// 流媒体与质感阴影档位（Infuse × Netflix 风格：景深微光与微浮起）。
abstract final class AppShadows {
  /// 卡片悬停时的流光与环境景深光晕
  static List<BoxShadow> cardHover(Color glowColor) => [
        BoxShadow(
          color: glowColor.withValues(alpha: 0.18),
          blurRadius: 16,
          offset: const Offset(0, 6),
          spreadRadius: 1,
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.25),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];

  /// 侧边栏与悬浮面板环境投影
  static List<BoxShadow> subtleDepth() => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.12),
          blurRadius: 20,
          offset: const Offset(2, 0),
        ),
      ];
}

/// 常用视觉渐变（Infuse × Netflix 画报流媒体遮罩）。
abstract final class AppGradients {
  /// 海报卡片自下而上的全景无边界黑场融合渐变
  static const LinearGradient posterCardMask = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.45, 0.75, 1.0],
    colors: [
      Colors.transparent,
      Color(0x1A000000),
      Color(0x99000000),
      Color(0xF0101014),
    ],
  );
}

