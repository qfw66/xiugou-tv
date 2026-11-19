import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';
import '../storage/data_restore_guard.dart';
import 'webdav_repository.dart';

class WebDavProfile {
  final String id;
  final String url;
  final String username;
  final String password;

  const WebDavProfile._(this.id, this.url, this.username, this.password);

  factory WebDavProfile.create(
    String url, {
    String username = '',
    String password = '',
  }) {
    final connection = WebDavConnection.parse(
      url,
      username: username,
      password: password,
    );
    final normalized = connection.root.toString();
    final user = username.trim();
    final id = sha256
        .convert(utf8.encode(jsonEncode([normalized, user])))
        .toString();
    return WebDavProfile._(id, normalized, user, password);
  }

  WebDavConnection connect() =>
      WebDavConnection.parse(url, username: username, password: password);

  Map<String, String> _toJson() => {
    'url': url,
    'username': username,
    'password': password,
  };
}

/// 可直接展示给用户的保存条件错误；不携带原始凭据或系统异常。
class WebDavProfileStoreException extends FormatException {
  const WebDavProfileStoreException(super.message);
}

abstract class WebDavProfileStore {
  factory WebDavProfileStore({
    Future<Directory> Function()? directory,
    MethodChannel? channel,
  }) = FileWebDavProfileStore;

  Future<List<WebDavProfile>> read();
  Future<List<WebDavProfile>> save(
    WebDavProfile profile, {
    String? replacingId,
  });
  Future<List<WebDavProfile>> remove(String id);
}

class FileWebDavProfileStore implements WebDavProfileStore {
  static const fileName = 'webdav_connections.bin';
  static const lockFileName = 'webdav_connections.lock';
  static const maxProfiles = 20;
  static const _maxBytes = 1024 * 1024;
  static Future<void> _writes = Future<void>.value();
  static int _sequence = 0;

  final Future<Directory> Function() _directory;
  final MethodChannel _channel;

  FileWebDavProfileStore({
    Future<Directory> Function()? directory,
    MethodChannel? channel,
  }) : _directory = directory ?? WindowsConfigStorage().getStorageDirectory,
       _channel = channel ?? const MethodChannel('xiugou/webdav_secrets');

  @override
  Future<List<WebDavProfile>> read() async {
    try {
      await _writes;
      final dir = await _directory();
      if (!await dir.exists()) return const [];
      final lock = await File(
        p.join(dir.path, lockFileName),
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        return await _read(File(p.join(dir.path, fileName)));
      } finally {
        await lock.close();
      }
    } catch (_) {
      throw const FormatException('已保存的 WebDAV 连接无法读取，可继续临时连接');
    }
  }

  Future<List<WebDavProfile>> _read(File file) async {
    if (!await file.exists()) return const [];
    if (await file.length() > _maxBytes) throw const FormatException();
    final encrypted = await file.readAsBytes();
    final clear = await _channel.invokeMethod<Uint8List>(
      'unprotect',
      encrypted,
    );
    if (clear == null || clear.isEmpty || clear.length > _maxBytes) {
      throw const FormatException();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(clear));
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['connections'] is! List) {
      throw const FormatException();
    }
    final values = decoded['connections'] as List;
    if (values.length > maxProfiles) throw const FormatException();
    final entries = <WebDavProfile>[];
    final identities = <String>{};
    for (final value in values) {
      if (value is! Map ||
          value['url'] is! String ||
          value['username'] is! String ||
          value['password'] is! String) {
        throw const FormatException();
      }
      final entry = WebDavProfile.create(
        value['url'] as String,
        username: value['username'] as String,
        password: value['password'] as String,
      );
      if (!identities.add(entry.id)) throw const FormatException();
      entries.add(entry);
    }
    return List.unmodifiable(entries);
  }

  @override
  Future<List<WebDavProfile>> save(
    WebDavProfile profile, {
    String? replacingId,
  }) => _change((entries) {
    final remaining = entries
        .where((entry) => entry.id != profile.id && entry.id != replacingId)
        .toList();
    if (remaining.length >= maxProfiles) {
      throw const WebDavProfileStoreException(
        '最多保存 20 个 WebDAV 连接，请先移除不再使用的记录',
      );
    }
    return [profile, ...remaining];
  });

  @override
  Future<List<WebDavProfile>> remove(String id) =>
      _change((entries) => entries.where((entry) => entry.id != id).toList());

  Future<List<WebDavProfile>> _change(
    List<WebDavProfile> Function(List<WebDavProfile>) update,
  ) {
    final operation = _writes.then((_) async {
      if (dataRestorePendingRestart) {
        throw const DataRestorePendingRestartException();
      }
      final dir = await _directory();
      await dir.create(recursive: true);
      final lock = await File(
        p.join(dir.path, lockFileName),
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        if (dataRestorePendingRestart) {
          throw const DataRestorePendingRestartException();
        }
        final file = File(p.join(dir.path, fileName));
        final entries = List<WebDavProfile>.unmodifiable(
          update(await _read(file)),
        );
        final clear = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'connections': entries.map((entry) => entry._toJson()).toList(),
            }),
          ),
        );
        final Uint8List? encrypted;
        try {
          if (clear.length > _maxBytes) {
            throw const WebDavProfileStoreException('连接记录过大，请缩短地址或凭据');
          }
          encrypted = await _channel.invokeMethod<Uint8List>('protect', clear);
        } finally {
          clear.fillRange(0, clear.length, 0);
        }
        if (encrypted == null ||
            encrypted.isEmpty ||
            encrypted.length > _maxBytes) {
          throw const WebDavProfileStoreException('系统未能安全保存连接记录');
        }
        final temporary = File('${file.path}.tmp-$pid-${++_sequence}');
        try {
          await temporary.writeAsBytes(encrypted, flush: true);
          if (dataRestorePendingRestart) {
            throw const DataRestorePendingRestartException();
          }
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
        return entries;
      } finally {
        await lock.close();
      }
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation.onError((Object error, StackTrace stack) {
      if (error is DataRestorePendingRestartException) throw error;
      if (error is WebDavProfileStoreException) throw error;
      throw const FormatException('连接记录未保存，请检查数据目录权限或重试；原记录已保留');
    });
  }
}
