import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// User-selected filesystem subtitles, scoped to the current mpv open.
class LocalSubtitleFiles {
  static const extensions = ['srt', 'ass', 'ssa', 'vtt'];
  Future<void>? _pending;

  // A replacement media open must follow a sub-add already submitted to mpv.
  // It need not wait for the file picker or filesystem validation.
  Future<void>? get pending => _pending;

  static Future<String> checkedPath(String path) async {
    final ext = p.extension(path).toLowerCase();
    if (!p.isAbsolute(path) || !extensions.any((e) => ext == '.$e')) {
      throw UnsupportedError('请选择本地 SRT、ASS、SSA 或 VTT 字幕文件');
    }
    final file = File(p.normalize(path));
    try {
      if ((await file.stat()).type != FileSystemEntityType.file) {
        throw UnsupportedError('无法读取字幕文件，请重新选择');
      }
      final input = await file.open();
      try {
        final length = await input.length();
        if (length > 32 * 1024 * 1024) {
          throw UnsupportedError('字幕文件超过 32 MB');
        }
        if (!await _hasCue(ext, _lines(input, length))) {
          throw UnsupportedError('未识别到有效的文本字幕，请选择其他文件');
        }
      } finally {
        await input.close();
      }
    } on FileSystemException {
      throw UnsupportedError('无法读取字幕文件，请检查文件是否存在或可读');
    }
    return file.path;
  }

  static Stream<String> _lines(RandomAccessFile file, int length) {
    Stream<String> chunks() async* {
      Endian? order;
      for (int pos = 0; pos < length;) {
        final bytes = await file.read((length - pos).clamp(0, 64 * 1024));
        if (bytes.isEmpty) return;
        final data = ByteData.sublistView(bytes);
        var start = 0;
        if (pos == 0 && bytes.length >= 2) {
          final bom = data.getUint16(0);
          if (bom == 0xfffe || bom == 0xfeff) {
            order = bom == 0xfffe ? Endian.little : Endian.big;
            start = 2;
          }
        }
        if (order != null && bytes.length.isOdd) {
          throw UnsupportedError('UTF-16 字幕文件不完整');
        }
        // Only the ASCII timing/format markers matter here. mpv decodes the original file.
        final text = order == null
            ? utf8.decode(bytes, allowMalformed: true)
            : String.fromCharCodes([
                for (var i = start; i < bytes.length; i += 2)
                  data.getUint16(i, order),
              ]);
        if (text.contains('\x00')) throw UnsupportedError('字幕文件包含二进制数据');
        yield text;
        pos += bytes.length;
      }
    }

    return const LineSplitter().bind(chunks());
  }

  static final _timeLine = RegExp(
    r'^(?:\d+:)?\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*(?:\d+:)?\d{2}:\d{2}[,.]\d{1,3}(?:\s|$)',
  );
  static final _dialogue = RegExp(
    r'^Dialogue:\s*[^,]*,\s*\d+:\d{2}:\d{2}\.\d{1,3}\s*,\s*\d+:\d{2}:\d{2}\.\d{1,3}\s*,(?:[^,]*,){6}\s*\S',
    caseSensitive: false,
  );

  // libass will happily select a header-only file and hide the previous track.
  static Future<bool> _hasCue(String ext, Stream<String> lines) async {
    final ass = ext == '.ass' || ext == '.ssa';
    var header = false, events = false, wantText = false, skipBlock = false;
    await for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) {
        wantText = false;
        skipBlock = false;
        continue;
      }
      if (!header) {
        if (ass && line.startsWith(';')) continue;
        header = true;
        if (ass) {
          if (line.toLowerCase() != '[script info]') return false;
          continue;
        }
        if (ext == '.vtt') {
          if (!RegExp(r'^WEBVTT(?:\s|$)').hasMatch(line)) return false;
          continue;
        }
        if (!_timeLine.hasMatch(line) && int.tryParse(line) == null) {
          return false;
        }
      }
      if (ass) {
        if (line.startsWith('[')) events = line.toLowerCase() == '[events]';
        if (events && _dialogue.hasMatch(line)) return true;
      } else {
        if (skipBlock) continue;
        if (wantText) return true;
        if (ext == '.vtt' &&
            RegExp(r'^(?:NOTE|STYLE|REGION)(?:\s|$)').hasMatch(line)) {
          skipBlock = true;
        }
        wantText = _timeLine.hasMatch(line);
      }
    }
    return false;
  }

  Future<bool> load(
    NativePlayer player,
    String path,
    bool Function() current,
  ) async {
    final String filename;
    try {
      filename = await checkedPath(path);
    } on UnsupportedError {
      if (!current()) return false;
      rethrow;
    }
    final previous = _pending;
    if (previous != null) await previous;
    if (!current()) return false;
    final result = _attach(player, filename, current);
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending = settled;
    try {
      return await result;
    } finally {
      if (identical(_pending, settled)) _pending = null;
    }
  }

  Future<bool> _attach(
    NativePlayer player,
    String file,
    bool Function() current,
  ) async {
    final previous = await player.getProperty('current-tracks/sub/id');
    if (!current()) return false;
    try {
      await player.command([
        'sub-add',
        file,
        'cached',
        p.basename(file),
      ], waitForInitialization: false);
      if (!current()) return false;
      final selected = await player.getProperty('current-tracks/sub/id');
      final filename = await player.getProperty(
        'current-tracks/sub/external-filename',
      );
      if (!current()) return false;
      if (selected.isNotEmpty && p.equals(filename, file)) return true;
    } catch (_) {
      if (!current()) return false;
    }
    final now = await player.getProperty('current-tracks/sub/id');
    if (!current()) return false;
    if (now != previous) {
      await player.setProperty(
        'sid',
        previous.isEmpty ? 'no' : previous,
        waitForInitialization: false,
      );
    }
    throw UnsupportedError('播放器未能加载这份字幕，请检查文件格式');
  }
}
