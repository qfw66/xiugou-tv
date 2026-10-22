/// 把 Java 侧 `printStackTrace()` 刷出来的多行堆栈折叠成一行。
///
/// <p>背景：加固载荷（ftyguard/wexguard）里大量 `catch (Exception e) { e.printStackTrace(); }`，
/// 一条异常就会往 stderr 打 15~25 行。这些异常**载荷自己已经 catch**，数据不受影响
/// （例如豆豆站的 `StringIndexOutOfBoundsException`，7 个分类各打一次堆栈但都正常返回列表）。
/// Debug 模式下 stderr 会转发到 Flutter 控制台，于是「看起来像崩了」。
///
/// <p>本过滤器只改**显示**，不吞信息：
/// - 普通行原样透传；
/// - 一条堆栈折叠成 `首行（堆栈 N 行已折叠；同类第 K 次）`；
/// - 同一异常超过 [spamThreshold] 次后，改为每 N 次打一条，避免站点死循环刷屏；
/// - [lastMeaningfulLine] 始终指向「有意义的最后一行」（堆栈取首行），供上层 `lastError` 使用。
class CompanionStderrFilter {
  CompanionStderrFilter({this.spamThreshold = 20});

  /// 同一异常超过该次数后降频（每 N 次打一条）。
  final int spamThreshold;

  final Map<String, int> _counts = <String, int>{};

  String? _header;
  int _frames = 0;
  String? _lastMeaningful;

  /// 最近一条有意义的 stderr（堆栈场景取首行，而不是帧）。
  String? get lastMeaningfulLine => _lastMeaningful;

  /// 同一异常首行出现的累计次数（测试与诊断用）。
  int countOf(String header) => _counts[header] ?? 0;

  /// 喂入一行，返回需要打印的行（0 行 = 被折叠，1 行 = 需要打印）。
  List<String> feed(String line) {
    if (_header != null) {
      if (_isContinuation(line)) {
        _frames++;
        return const <String>[];
      }
      final closed = _closeBlock();
      // 当前行不是上一块的延续：先收尾，再把它当新行重新处理。
      return <String>[...closed, ...feed(line)];
    }
    if (_isHeader(line)) {
      _header = line;
      _frames = 0;
      _lastMeaningful = line;
      return const <String>[];
    }
    _lastMeaningful = line;
    return <String>[line];
  }

  /// 流结束（子进程退出）时冲掉未闭合的堆栈块。
  List<String> flush() => _header == null ? const <String>[] : _closeBlock();

  List<String> _closeBlock() {
    final header = _header!;
    final frames = _frames;
    _header = null;
    _frames = 0;

    final nth = (_counts[header] ?? 0) + 1;
    _counts[header] = nth;
    if (nth > spamThreshold && nth % spamThreshold != 0) {
      return const <String>[];
    }

    final buffer = StringBuffer(header);
    final details = <String>[
      if (frames > 0) '堆栈 $frames 行已折叠',
      if (nth > 1) '同类第 $nth 次',
    ];
    if (details.isNotEmpty) buffer.write('（${details.join('；')}）');
    return <String>[buffer.toString()];
  }

  /// 堆栈首行：`java.lang.XxxException: msg` / `Caused by: ...` / `Exception in thread "t" ...`。
  static final RegExp _headerPattern = RegExp(
    r'^(?:Caused by:\s*)?(?:[A-Za-z_$][\w$]*\.)+[A-Za-z_$][\w$]*(?:Exception|Error)(?::.*)?$',
  );
  static final RegExp _threadHeaderPattern = RegExp(
    r'^Exception in thread "[^"]*"\s+(?:[A-Za-z_$][\w$]*\.)+[A-Za-z_$][\w$]*(?:Exception|Error)(?::.*)?$',
  );

  /// 帧 / `... 18 more` / 嵌套 `Caused by:` / `Suppressed:` 都算同一块的延续。
  static final RegExp _framePattern = RegExp(r'^\s+at\s+\S');
  static final RegExp _morePattern = RegExp(r'^\s*\.\.\.\s+\d+\s+more\s*$');
  static final RegExp _causePattern = RegExp(r'^\s*Caused by:\s*\S');
  static final RegExp _suppressedPattern = RegExp(r'^\s*Suppressed:\s*\S');

  static bool _isHeader(String line) =>
      _headerPattern.hasMatch(line) || _threadHeaderPattern.hasMatch(line);

  static bool _isContinuation(String line) =>
      _framePattern.hasMatch(line) ||
      _morePattern.hasMatch(line) ||
      _causePattern.hasMatch(line) ||
      _suppressedPattern.hasMatch(line);
}
