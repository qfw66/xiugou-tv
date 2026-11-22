import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models/vod_config.dart';

/// PG 的复合扩展混合了资源地址、开关和清单正文，不能作为一个 URL 解析。
class PgPackageResources {
  const PgPackageResources._();

  static const _separator = r'$$$';
  static const _token = 'lib/tokenm.json';
  static const _maxListBytes = 64 * 1024;
  static const _shareFiles = {
    'csp_PushShare': {'pushshare.txt'},
    'csp_AliShare': {'alishare.txt', 'alishare.ebook.txt'},
    'csp_QuarkShare': {'quarkshare.txt'},
    'csp_P123Share': {'123share.txt'},
    'csp_P189Share': {'189share.txt'},
    'csp_ThunderShare': {'thundershare.txt'},
    'csp_UCShare': {'ucshare.txt'},
    'csp_P115Share': {'115share.txt'},
  };
  static final _quarkRow = RegExp(r'^(?:self|[0-9a-fA-F]{12})[ \t]+\S');
  static final _shareRow = RegExp(
    r'^[A-Za-z0-9_-]{1,128}(?:\?[A-Za-z0-9_]{1,24}=[A-Za-z0-9_-]{1,64})?[ \t]+\S',
  );
  static final _pushRow = RegExp(r'^(https?://[^\s\\]+)[ \t]+\S');
  static final _magnetRow = RegExp(
    r'^magnet:\?xt=urn:btih:[0-9a-fA-F]{40}[ \t]+\S',
  );

  static bool _validPushRow(String line) {
    if (_magnetRow.hasMatch(line)) return true;
    final match = _pushRow.firstMatch(line);
    if (match == null) return false;
    final uri = Uri.tryParse(match[1]!);
    return uri != null && uri.host.isNotEmpty && uri.userInfo.isEmpty;
  }

  static String? _declaredShareFile(Site site) {
    final allowed = _shareFiles[site.api];
    if (allowed == null ||
        !site.isJarSource ||
        site.jar?.split(';').first.trim() != './pg.jar') {
      return null;
    }
    final fields = site.ext?.split(_separator);
    if (fields == null || fields.length < 2 || fields.first != './$_token') {
      return null;
    }
    for (final name in allowed) {
      if (fields[1] == './lib/$name') return name;
    }
    return null;
  }

  /// 本地配置在交给站点前逐字段检查；缺失的包内旁文件保留原 URI，包外引用置空。
  static Future<Map<Site, String>> localExtensions(
    File config,
    List<Site> sites,
  ) async {
    final base = config.absolute.uri;
    final checked = <String, Future<File?>>{};
    final lists = <String, Future<String?>>{};
    final overrides = <Site, String>{};
    Future<bool>? hasJar;
    for (final site in sites) {
      final fields = _resourceFields(site, base);
      if (fields == null) continue;
      final name = _declaredShareFile(site);
      for (var i = 0; i < fields.length; i++) {
        final value = fields[i];
        if (!value.toLowerCase().startsWith('file:') &&
            !value.startsWith('./') &&
            !value.startsWith('../') &&
            !p.isAbsolute(value)) {
          continue;
        }
        final file = await checked.putIfAbsent(
          value,
          () => _packageFile(config, value),
        );
        if (file == null) {
          fields[i] = '';
        } else if (i == 1 &&
            name != null &&
            await (hasJar ??= _hasPackageJar(config))) {
          fields[i] =
              await lists.putIfAbsent(name, () => _readList(file, name)) ??
              value;
        }
      }
      overrides[site] = fields.join(_separator);
    }
    return overrides;
  }

  static Future<File?> _packageFile(File config, String reference) async {
    try {
      final base = config.absolute.uri;
      final uri = p.isAbsolute(reference)
          ? Uri.file(reference)
          : base.resolve(reference);
      if (!uri.isScheme('file') || uri.host != base.host) return null;
      final root = config.absolute.parent;
      final target = p.normalize(uri.toFilePath());
      if (!p.isWithin(root.path, target)) return null;
      var path = await root.resolveSymbolicLinks();
      for (final part in p.split(p.relative(target, from: root.path))) {
        path = p.join(path, part);
        if (await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.link) {
          return null;
        }
      }
      return File(path);
    } on FileSystemException {
      return null;
    } on UnsupportedError {
      return null;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static Future<bool> _hasPackageJar(File config) async {
    final jar = await _packageFile(config, './pg.jar');
    return jar != null && await _regularFile(jar);
  }

  static Future<bool> _regularFile(File file) async {
    try {
      return await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file &&
          p.equals(await file.resolveSymbolicLinks(), file.path);
    } on FileSystemException {
      return false;
    }
  }

  static Future<String?> _readList(File file, String name) async {
    try {
      if (!await _regularFile(file)) return null;
      final input = await file.open();
      try {
        final bytes = await input.read(_maxListBytes + 1);
        if (bytes.length > _maxListBytes) return null;
        final text = utf8.decode(bytes).trim();
        if (text.isEmpty || text.contains(_separator)) return null;
        final lines = const LineSplitter()
            .convert(text)
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty);
        // PG 用首行区分清单与远程 URL。注释行不产生条目，也不会把第一条分享误当成订阅。
        if (name == 'pushshare.txt') {
          return lines.every(_validPushRow) ? '#\n$text' : null;
        }
        final row = name == 'quarkshare.txt' ? _quarkRow : _shareRow;
        return !text.startsWith('http') && lines.every(row.hasMatch)
            ? text
            : null;
      } finally {
        await input.close();
      }
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static String? resolve(Site site, Uri base) {
    final fields = _resourceFields(site, base);
    if (fields != null) return fields.join(_separator);
    // PG 复合字段不能退回单 URL 解析：即使资源根不匹配，也应保留远程 URL 的原始转义。
    final ext = site.ext;
    return site.isJarSource &&
            ext != null &&
            ext.startsWith('./$_token$_separator')
        ? ext
        : null;
  }

  /// 镜像可能已把首字段和 JAR 改为绝对地址，只在两者能证明同一资源根时展开。
  static List<String>? _resourceFields(Site site, Uri base) {
    final jar = site.jar;
    final ext = site.ext;
    if (!site.isJarSource ||
        jar == null ||
        ext == null ||
        !ext.contains(_separator)) {
      return null;
    }
    final fields = ext.split(_separator);
    try {
      final jarUri = base.resolve(jar.split(';').first.trim());
      if (!{'file', 'http', 'https'}.contains(jarUri.scheme) ||
          jarUri.pathSegments.lastOrNull != 'pg.jar') {
        return null;
      }
      final root = jarUri.resolve('.');
      if (base.resolve(fields.first) != root.resolve(_token)) return null;
      for (var i = 0; i < fields.length; i++) {
        if (fields[i].startsWith('./lib/')) {
          fields[i] = root.resolve(fields[i]).toString();
        }
      }
      return fields;
    } on FormatException {
      return null;
    }
  }
}
