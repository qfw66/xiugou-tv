import 'dart:convert';
import 'dart:typed_data';

/// 配置正文的 `2423` 十六进制 AES 外壳：对齐手机端 `Decoder.cbc`。
///
/// 载体布局（整体为十六进制文本）：
/// `hex("$#" + key + "#$")` + `hex(密文)` + `hex(iv)`（末尾 26 个十六进制字符，即 13 字节）。
/// key 与 iv 右补 ASCII `0` 至 16 字节后按 AES-128/CBC/PKCS5 解密。
class ConfigCipher {
  const ConfigCipher._();

  static const String prefix = '2423';
  static const String _keyEnd = '2324';
  static const int _ivHexLength = 26;
  static final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]+$');

  /// 是否是 `2423` 外壳（只看前缀，正文合法性由 [tryDecryptCbc] 判定）。
  static bool looksEncrypted(String text) => text.startsWith(prefix);

  /// 解密 `2423` 外壳；格式不符或解密失败时返回 null。
  static String? tryDecryptCbc(String content) {
    final text = content.replaceAll(RegExp(r'\s+'), '');
    if (!looksEncrypted(text) || !_hexPattern.hasMatch(text)) return null;
    final keyEnd = text.indexOf(_keyEnd, prefix.length);
    if (keyEnd < 0) return null;
    final dataStart = keyEnd + _keyEnd.length;
    final ivStart = text.length - _ivHexLength;
    if (ivStart <= dataStart) return null;
    final cipherHex = text.substring(dataStart, ivStart);
    if (cipherHex.isEmpty || cipherHex.length % 32 != 0) return null;
    try {
      final key = utf8
          .decode(_hexToBytes(text.substring(0, dataStart)))
          .replaceAll(r'$#', '')
          .replaceAll(r'#$', '');
      final iv = utf8.decode(_hexToBytes(text.substring(ivStart)));
      final plain = _Aes128.decryptCbc(
        _hexToBytes(cipherHex),
        _padEnd(key),
        _padEnd(iv),
      );
      return plain == null ? null : utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// 手机端 `padEnd`：右补 `0` 到 16 字节，超长截断。
  static Uint8List _padEnd(String value) {
    final bytes = utf8.encode('${value}0000000000000000');
    return Uint8List.fromList(bytes.sublist(0, 16));
  }

  static Uint8List _hexToBytes(String hex) {
    if (hex.length.isOdd) throw const FormatException('hex 长度为奇数');
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// 最小 AES-128 解密实现（FIPS-197 逆密码），只服务于配置外壳解密。
class _Aes128 {
  static final Uint8List _sbox = Uint8List(256);
  static final Uint8List _invSbox = Uint8List(256);
  static bool _ready = false;

  static void _init() {
    if (_ready) return;
    // 通过 GF(2^8) 上的 3 与 3^-1 遍历生成 S 盒，避免手抄常量表出错。
    var p = 1, q = 1;
    do {
      p = (p ^ ((p << 1) & 0xff) ^ ((p & 0x80) != 0 ? 0x1b : 0)) & 0xff;
      q ^= (q << 1) & 0xff;
      q ^= (q << 2) & 0xff;
      q ^= (q << 4) & 0xff;
      if ((q & 0x80) != 0) q ^= 0x09;
      final x = q ^ _rotl(q, 1) ^ _rotl(q, 2) ^ _rotl(q, 3) ^ _rotl(q, 4);
      _sbox[p] = (x ^ 0x63) & 0xff;
    } while (p != 1);
    _sbox[0] = 0x63;
    for (var i = 0; i < 256; i++) {
      _invSbox[_sbox[i]] = i;
    }
    _ready = true;
  }

  static int _rotl(int x, int shift) => ((x << shift) | (x >> (8 - shift))) & 0xff;

  static int _xtime(int x) => ((x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0)) & 0xff;

  static int _mul(int a, int b) {
    var result = 0;
    while (b > 0) {
      if ((b & 1) != 0) result ^= a;
      a = _xtime(a);
      b >>= 1;
    }
    return result;
  }

  static Uint8List _expandKey(Uint8List key) {
    final w = Uint8List(176)..setRange(0, 16, key);
    var rcon = 1;
    for (var i = 16; i < 176; i += 4) {
      var t0 = w[i - 4], t1 = w[i - 3], t2 = w[i - 2], t3 = w[i - 1];
      if (i % 16 == 0) {
        final tmp = t0;
        t0 = _sbox[t1] ^ rcon;
        t1 = _sbox[t2];
        t2 = _sbox[t3];
        t3 = _sbox[tmp];
        rcon = _xtime(rcon);
      }
      w[i] = w[i - 16] ^ t0;
      w[i + 1] = w[i - 15] ^ t1;
      w[i + 2] = w[i - 14] ^ t2;
      w[i + 3] = w[i - 13] ^ t3;
    }
    return w;
  }

  static void _decryptBlock(Uint8List s, Uint8List w) {
    for (var i = 0; i < 16; i++) {
      s[i] ^= w[160 + i];
    }
    for (var round = 9; round >= 0; round--) {
      _invShiftRows(s);
      for (var i = 0; i < 16; i++) {
        s[i] = _invSbox[s[i]];
      }
      for (var i = 0; i < 16; i++) {
        s[i] ^= w[round * 16 + i];
      }
      if (round > 0) _invMixColumns(s);
    }
  }

  /// 状态按列存放：s[row + 4 * col]；第 r 行循环右移 r 位。
  static void _invShiftRows(Uint8List s) {
    for (var r = 1; r < 4; r++) {
      final row = [s[r], s[r + 4], s[r + 8], s[r + 12]];
      for (var c = 0; c < 4; c++) {
        s[r + 4 * ((c + r) % 4)] = row[c];
      }
    }
  }

  static void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _mul(a0, 14) ^ _mul(a1, 11) ^ _mul(a2, 13) ^ _mul(a3, 9);
      s[i + 1] = _mul(a0, 9) ^ _mul(a1, 14) ^ _mul(a2, 11) ^ _mul(a3, 13);
      s[i + 2] = _mul(a0, 13) ^ _mul(a1, 9) ^ _mul(a2, 14) ^ _mul(a3, 11);
      s[i + 3] = _mul(a0, 11) ^ _mul(a1, 13) ^ _mul(a2, 9) ^ _mul(a3, 14);
    }
  }

  /// 单块解密（测试向量校验用）。
  static Uint8List decryptBlock(Uint8List block, Uint8List key) {
    _init();
    final state = Uint8List.fromList(block);
    _decryptBlock(state, _expandKey(key));
    return state;
  }

  /// AES-128/CBC 解密并去除 PKCS#5/7 填充；填充非法时返回 null。
  static Uint8List? decryptCbc(Uint8List data, Uint8List key, Uint8List iv) {
    if (data.isEmpty || data.length % 16 != 0) return null;
    _init();
    final w = _expandKey(key);
    final out = Uint8List(data.length);
    var prev = Uint8List.fromList(iv);
    for (var off = 0; off < data.length; off += 16) {
      final block = Uint8List.sublistView(data, off, off + 16);
      final state = Uint8List.fromList(block);
      _decryptBlock(state, w);
      for (var i = 0; i < 16; i++) {
        out[off + i] = state[i] ^ prev[i];
      }
      prev = Uint8List.fromList(block);
    }
    final pad = out.last;
    if (pad < 1 || pad > 16) return null;
    for (var i = out.length - pad; i < out.length; i++) {
      if (out[i] != pad) return null;
    }
    return Uint8List.sublistView(out, 0, out.length - pad);
  }
}

/// 仅供测试：FIPS-197 单块向量校验。
Uint8List debugAes128DecryptBlock(Uint8List block, Uint8List key) =>
    _Aes128.decryptBlock(block, key);
