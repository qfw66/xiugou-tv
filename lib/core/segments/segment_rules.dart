import 'segment_models.dart';

/// 共享片段提交校验（§44）——与服务端 `server/segments-worker/src/rules.js` 同口径。
///
/// 两端共用 `server/segments-worker/test/vectors.json` 做契约测试（test/segment_rules_test.dart），
/// **改规则要两边一起改**。客户端先校验是为了即时提示，服务端校验才是准绳。
class SegmentRuleViolation {
  const SegmentRuleViolation(this.code, this.message);
  final String code;
  final String message;
}

abstract final class SegmentRules {
  static const int _s = 1000;
  static const int _min = 60 * _s;

  static const int minLen = 3 * _s;
  static const int minDuration = 1 * _min;
  static const int maxDuration = 6 * 60 * _min;
  static const int endSlack = 2 * _s;

  static int maxLen(SegmentCategory c) => switch (c) {
        SegmentCategory.intro => 5 * _min,
        SegmentCategory.outro => 10 * _min,
        SegmentCategory.recap => 5 * _min,
        SegmentCategory.preview => 5 * _min,
        SegmentCategory.ad => 3 * _min,
        SegmentCategory.other => 10 * _min,
      };

  static bool _where(SegmentCategory c, int st, int en, int d) => switch (c) {
        SegmentCategory.intro => st <= _minOf(10 * _min, d * 0.3),
        SegmentCategory.outro => st >= d * 0.6 && en >= d * 0.8,
        SegmentCategory.recap => st <= _minOf(15 * _min, d * 0.4),
        SegmentCategory.preview => st >= d * 0.7,
        SegmentCategory.ad || SegmentCategory.other => true,
      };

  static double _minOf(num a, num b) => (a < b ? a : b).toDouble();

  /// 合法返回 null。
  static SegmentRuleViolation? validate({
    required SegmentCategory category,
    required int startMs,
    required int endMs,
    required int durationMs,
  }) {
    SegmentRuleViolation bad(String code, String message) => SegmentRuleViolation(code, message);
    if (durationMs < minDuration || durationMs > maxDuration) {
      return bad('bad_duration', '本集时长异常，无法共享');
    }
    if (startMs < 0 || endMs <= startMs || endMs > durationMs + endSlack) {
      return bad('bad_range', '开始 / 结束时间不正确');
    }
    final len = endMs - startMs;
    if (len < minLen) return bad('too_short', '片段太短（至少 3 秒）');
    if (len > maxLen(category)) return bad('too_long', '片段太长，不像${_label(category)}');
    if (!_where(category, startMs, endMs, durationMs)) {
      return bad('bad_position', '时间位置不像${_label(category)}，未上传');
    }
    return null;
  }

  static String _label(SegmentCategory c) => c == SegmentCategory.other ? '其他片段' : c.label;
}
