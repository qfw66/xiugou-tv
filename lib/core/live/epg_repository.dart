import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';
import '../config/models/vod_config.dart';
import 'epg_program.dart';
import 'live_text_loader.dart';

/// 按需加载 EPG，同源请求合并；不以节目单成功与否决定频道能否播放。
class EpgRepository {
  final Dio _dio;
  final bool _ownsDio;
  final DateTime Function() _clock;
  final _cache = <String, ({DateTime time, _EpgFeed feed})>{};
  final _pending = <String, Future<_EpgFeed>>{};
  var _disposed = false;

  EpgRepository({Dio? dio, DateTime Function()? clock})
      : _ownsDio = dio == null,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
            )),
        _clock = clock ?? DateTime.now;

  Future<EpgSchedule> load(Live channel,
      {DateTime? date, bool forceRefresh = false}) async {
    if (_disposed) throw StateError('节目单仓库已关闭');
    final template = channel.epg?.trim();
    if (template == null || template.isEmpty) return const EpgSchedule([]);
    final beijing = (date ?? _clock()).toUtc().add(const Duration(hours: 8));
    final day = DateTime.utc(beijing.year, beijing.month, beijing.day);
    final dateKey = day.toIso8601String().substring(0, 10);
    var url = template;
    for (final entry in {
      'date': dateKey,
      'name': channel.epgName ?? channel.name,
      'id': channel.epgId ?? channel.name,
    }.entries) {
      url = url.replaceAll(
        RegExp(r'(\{|%7B)' + entry.key + r'(\}|%7D)', caseSensitive: false),
        Uri.encodeComponent(entry.value),
      );
    }
    final key = '$url\u0000$dateKey';
    final existing = _cache[key];
    _EpgFeed feed;
    if (!forceRefresh &&
        existing != null &&
        _clock().difference(existing.time) < const Duration(minutes: 30)) {
      feed = existing.feed;
    } else {
      feed = await (_pending[key] ??= _fetch(url, day, key));
    }
    final start = day.subtract(const Duration(hours: 8));
    final end = start.add(const Duration(days: 1));
    return EpgSchedule(List.unmodifiable(feed.forChannel(channel).where(
        (program) =>
            program.start.isBefore(end) && program.end.isAfter(start))));
  }

  Future<_EpgFeed> _fetch(String url, DateTime day, String key) async {
    try {
      final document = await loadLiveText(Uri.parse(url), dio: _dio);
      final feed = _EpgFeed.parse(document.content, day);
      if (!_disposed) {
        _cache.remove(key);
        if (_cache.length >= 12) _cache.remove(_cache.keys.first);
        _cache[key] = (time: _clock(), feed: feed);
      }
      return feed;
    } finally {
      _pending.remove(key);
    }
  }

  /// 清空节目单内存缓存（SET-09）。
  ///
  /// 不取消在途请求：在途请求完成后仍会写回缓存，下一次清理可再次清掉。
  void clearCache() => _cache.clear();

  void dispose() {
    _disposed = true;
    _cache.clear();
    if (_ownsDio) _dio.close(force: true);
  }
}

class _EpgFeed {
  final Map<String, List<EpgProgram>> byChannel;
  final Map<String, String?> aliases;
  final List<EpgProgram>? jsonPrograms;

  const _EpgFeed(this.byChannel, this.aliases, {this.jsonPrograms});

  List<EpgProgram> forChannel(Live channel) {
    if (jsonPrograms != null) return jsonPrograms!;
    final id = channel.epgId;
    if (id != null && byChannel.containsKey(id)) return byChannel[id]!;
    for (final name in [channel.epgName, channel.name, id]) {
      if (name == null) continue;
      final matched = aliases[_normalize(name)];
      if (matched != null) return byChannel[matched] ?? const [];
    }
    return const [];
  }

  static _EpgFeed parse(String content, DateTime requestedDay) {
    final text = content.trim();
    if (text.startsWith('{')) return _parseJson(text, requestedDay);
    return _parseXml(text);
  }

  static _EpgFeed _parseJson(String text, DateTime requestedDay) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw const FormatException('JSON 节目单格式无效');
    final map = decoded['data'] is Map ? decoded['data'] as Map : decoded;
    final rows = map['epg_data'] ?? map['programmes'] ?? map['programs'];
    if (rows is! List) throw const FormatException('JSON 节目单缺少 epg_data 列表');
    final day = _parseDay(map['date']?.toString()) ?? requestedDay;
    final programs = <EpgProgram>[];
    for (final row in rows.whereType<Map>()) {
      final title = (row['title'] ?? row['name'])?.toString().trim() ?? '';
      final start = _jsonTime(row['start'], day);
      var end = _jsonTime(row['end'], day);
      if (title.isEmpty || start == null || end == null) continue;
      if (end.isBefore(start) &&
          _clockTime.hasMatch(row['end']?.toString() ?? '')) {
        end = end.add(const Duration(days: 1));
      }
      if (!end.isAfter(start)) continue;
      programs.add(EpgProgram(
        title: title,
        start: start,
        end: end,
        description: row['desc']?.toString() ?? row['description']?.toString(),
      ));
    }
    return _EpgFeed(const {}, const {}, jsonPrograms: _sort(programs));
  }

  static _EpgFeed _parseXml(String text) {
    XmlDocument document;
    try {
      document = XmlDocument.parse(text);
    } on XmlParserException {
      throw const FormatException('XMLTV 节目单无法解析');
    }
    if (document.rootElement.name.local != 'tv') {
      throw const FormatException('返回内容不是 XMLTV 节目单');
    }
    final aliases = <String, String?>{};
    void alias(String name, String id) {
      final key = _normalize(name);
      if (key.isEmpty) return;
      if (aliases.containsKey(key) && aliases[key] != id) {
        aliases[key] = null;
      } else {
        aliases[key] = id;
      }
    }

    for (final channel in document.findAllElements('channel')) {
      final id = channel.getAttribute('id');
      if (id == null || id.isEmpty) continue;
      alias(id, id);
      for (final name in channel.findElements('display-name')) {
        alias(name.innerText, id);
      }
    }
    final programs = <String, List<EpgProgram>>{};
    for (final node in document.findAllElements('programme')) {
      final id = node.getAttribute('channel');
      final titles = node.findElements('title');
      final title = titles.isEmpty ? '' : titles.first.innerText.trim();
      final start = _xmlTime(node.getAttribute('start'));
      final end = _xmlTime(node.getAttribute('stop'));
      if (id == null ||
          title.isEmpty ||
          start == null ||
          end == null ||
          !end.isAfter(start)) {
        continue;
      }
      alias(id, id);
      final descriptions = node.findElements('desc');
      (programs[id] ??= []).add(EpgProgram(
        title: title,
        start: start,
        end: end,
        description: descriptions.isEmpty ? null : descriptions.first.innerText,
      ));
    }
    return _EpgFeed({
      for (final entry in programs.entries) entry.key: _sort(entry.value),
    }, aliases);
  }

  static String _normalize(String value) =>
      value.replaceAll(RegExp(r'[\s_-]'), '').toUpperCase();

  static List<EpgProgram> _sort(List<EpgProgram> programs) {
    final unique = <String, EpgProgram>{};
    for (final program in programs) {
      final key =
          '${program.title}\u0000${program.start.toIso8601String()}\u0000${program.end.toIso8601String()}';
      unique.putIfAbsent(key, () => program);
    }
    return List.unmodifiable(unique.values.toList()
      ..sort((left, right) => left.start.compareTo(right.start)));
  }

  static final _clockTime = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$');

  static DateTime? _jsonTime(dynamic raw, DateTime day) {
    if (raw is num) {
      if (!raw.isFinite || raw.abs() > 8640000000000000) return null;
      final value = raw.toInt();
      return DateTime.fromMillisecondsSinceEpoch(
          value.abs() < 100000000000 ? value * 1000 : value,
          isUtc: true);
    }
    final value = raw?.toString().trim();
    if (value == null) return null;
    final match = _clockTime.firstMatch(value);
    if (match != null) {
      final hour = int.parse(match.group(1)!);
      final minute = int.parse(match.group(2)!);
      final second = int.parse(match.group(3) ?? '0');
      if (hour > 24 ||
          minute > 59 ||
          second > 59 ||
          (hour == 24 && (minute != 0 || second != 0))) {
        return null;
      }
      return DateTime.utc(day.year, day.month, day.day, hour, minute, second)
          .subtract(const Duration(hours: 8));
    }
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}[T ]').hasMatch(value)) return null;
    final hasZone =
        RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(value);
    return DateTime.tryParse(hasZone ? value : '$value+08:00')?.toUtc();
  }

  static DateTime? _parseDay(String? raw) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw ?? '');
    if (match == null) return null;
    return _utc(int.parse(match.group(1)!), int.parse(match.group(2)!),
        int.parse(match.group(3)!), 0, 0, 0);
  }

  static DateTime? _xmlTime(String? raw) {
    final match = RegExp(
      r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?(?:\s*(Z|[+-]\d{4}))?$',
    ).firstMatch(raw?.trim() ?? '');
    if (match == null) return null;
    final time = _utc(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!),
        int.parse(match.group(6) ?? '0'));
    if (time == null) return null;
    final zone = match.group(7);
    if (zone == null || zone == 'Z') return time;
    final hour = int.parse(zone.substring(1, 3));
    final minute = int.parse(zone.substring(3, 5));
    if (hour > 23 || minute > 59) return null;
    final offset =
        Duration(minutes: (hour * 60 + minute) * (zone[0] == '+' ? 1 : -1));
    return time.subtract(offset);
  }

  static DateTime? _utc(
      int year, int month, int day, int hour, int minute, int second) {
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31 ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      return null;
    }
    final time = DateTime.utc(year, month, day, hour, minute, second);
    return time.year == year && time.month == month && time.day == day
        ? time
        : null;
  }
}
