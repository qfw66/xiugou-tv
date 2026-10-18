/// 宽松 JSON 解析：对齐手机端 Gson(LEGACY_STRICT) 与 org.json 的容错范围。
///
/// 真实影视配置里大量存在严格 RFC 8259 不接受、但手机端能解析的写法：
/// `//` 与 `/* */` 注释、无引号的对象 key、无引号的字面量值、单引号字符串、
/// 对象与数组的尾随逗号。`dart:convert` 的 `jsonDecode` 会全部拒绝。
///
/// 与手机端 `com.github.catvod.utils.Json.parse` 行为对齐，使同一份配置
/// 在 PC 端能得到与手机端一致的解析结果。
class LenientJson {
  const LenientJson._();

  /// 解析 [source]；结构不可恢复时抛 [FormatException]。
  static dynamic parse(String source) {
    final parser = _Parser(source);
    final value = parser.parseValue();
    parser.skipTrivia();
    return value;
  }

  /// 解析失败时返回 null，便于调用方继续尝试其它解码路径。
  static dynamic tryParse(String source) {
    try {
      return parse(source);
    } on FormatException {
      return null;
    }
  }
}

const int _charTab = 0x09;
const int _charLf = 0x0A;
const int _charCr = 0x0D;
const int _charSpace = 0x20;
const int _charBom = 0xFEFF;

class _Parser {
  _Parser(this._text);

  final String _text;
  int _index = 0;

  bool get _atEnd => _index >= _text.length;
  String get _current => _text[_index];

  dynamic parseValue() {
    skipTrivia();
    if (_atEnd) throw const FormatException('意外的输入结束');
    final char = _current;
    if (char == '{') return _parseObject();
    if (char == '[') return _parseArray();
    if (char == '"' || char == "'") return _parseQuotedString();
    if (_consumeWord('true')) return true;
    if (_consumeWord('false')) return false;
    if (_consumeWord('null')) return null;
    if (_consumeWord('NaN')) return double.nan;
    if (_consumeWord('Infinity')) return double.infinity;
    final number = _tryParseNumber();
    if (number != null) return number;
    return _parseBareValue();
  }

  Map<String, dynamic> _parseObject() {
    final result = <String, dynamic>{};
    _index++; // 跳过 '{'
    skipTrivia();
    while (!_atEnd && _current != '}') {
      final key = _parseKey();
      skipTrivia();
      if (_atEnd || _current != ':') {
        throw FormatException('对象缺少 ":"（位置 $_index）');
      }
      _index++; // 跳过 ':'
      result[key] = parseValue();
      skipTrivia();
      if (!_atEnd && _current == ',') {
        _index++;
        skipTrivia();
        continue;
      }
      break;
    }
    if (_atEnd || _current != '}') {
      throw FormatException('对象未闭合（位置 $_index）');
    }
    _index++; // 跳过 '}'
    return result;
  }

  List<dynamic> _parseArray() {
    final result = <dynamic>[];
    _index++; // 跳过 '['
    skipTrivia();
    while (!_atEnd && _current != ']') {
      result.add(parseValue());
      skipTrivia();
      if (!_atEnd && _current == ',') {
        _index++;
        skipTrivia();
        continue;
      }
      break;
    }
    if (_atEnd || _current != ']') {
      throw FormatException('数组未闭合（位置 $_index）');
    }
    _index++; // 跳过 ']'
    return result;
  }

  /// 对象 key：带引号按字符串解析，无引号按裸标识符解析。
  String _parseKey() {
    if (_atEnd) throw const FormatException('对象 key 缺失');
    if (_current == '"' || _current == "'") return _parseQuotedString();
    final start = _index;
    while (!_atEnd) {
      final char = _current;
      if (char == ':' || char == ',' || char == '}') break;
      if (_isWhitespace(char)) break;
      _index++;
    }
    final key = _text.substring(start, _index).trim();
    if (key.isEmpty) throw FormatException('对象 key 为空（位置 $start）');
    return key;
  }

  /// 无引号的值：读到结构分隔符、注释起始或空白为止。
  ///
  /// `#`、`;` 是 Gson lenient 的裸值终止符（`nextUnquotedValue`），
  /// 保留它们可避免把后续注释吞进值里。
  String _parseBareValue() {
    final start = _index;
    while (!_atEnd) {
      final char = _current;
      if (char == ',' || char == '}' || char == ']') break;
      if (char == '#' || char == ';') break;
      if (_isWhitespace(char)) break;
      _index++;
    }
    final value = _text.substring(start, _index).trim();
    if (value.isEmpty) throw FormatException('无法识别的值（位置 $start）');
    return value;
  }

  String _parseQuotedString() {
    final quote = _current;
    _index++;
    final buffer = StringBuffer();
    while (true) {
      if (_atEnd) throw const FormatException('字符串未闭合');
      final char = _current;
      _index++;
      if (char == quote) break;
      if (char != r'\') {
        buffer.write(char);
        continue;
      }
      if (_atEnd) throw const FormatException('转义符后缺少字符');
      final escaped = _current;
      _index++;
      switch (escaped) {
        case 'n':
          buffer.write('\n');
        case 'r':
          buffer.write('\r');
        case 't':
          buffer.write('\t');
        case 'b':
          buffer.write('\b');
        case 'f':
          buffer.write('\f');
        case 'u':
          if (_index + 4 > _text.length) {
            throw const FormatException('\\u 转义不完整');
          }
          buffer.writeCharCode(
              int.parse(_text.substring(_index, _index + 4), radix: 16));
          _index += 4;
        default:
          buffer.write(escaped);
      }
    }
    return buffer.toString();
  }

  num? _tryParseNumber() {
    final start = _index;
    if (!_atEnd && (_current == '-' || _current == '+')) _index++;
    var digits = 0;
    while (!_atEnd && _isDigit(_current)) {
      _index++;
      digits++;
    }
    var isDouble = false;
    if (!_atEnd && _current == '.') {
      final dotIndex = _index;
      _index++;
      var fractionDigits = 0;
      while (!_atEnd && _isDigit(_current)) {
        _index++;
        fractionDigits++;
      }
      if (fractionDigits == 0) {
        _index = dotIndex;
      } else {
        isDouble = true;
      }
    }
    if (digits == 0 && !isDouble) {
      _index = start;
      return null;
    }
    if (!_atEnd && (_current == 'e' || _current == 'E')) {
      final expIndex = _index;
      _index++;
      if (!_atEnd && (_current == '-' || _current == '+')) _index++;
      var expDigits = 0;
      while (!_atEnd && _isDigit(_current)) {
        _index++;
        expDigits++;
      }
      if (expDigits == 0) {
        _index = expIndex;
      } else {
        isDouble = true;
      }
    }
    final raw = _text.substring(start, _index);
    if (isDouble) return double.tryParse(raw);
    return int.tryParse(raw) ?? double.tryParse(raw);
  }

  bool _consumeWord(String word) {
    if (!_text.startsWith(word, _index)) return false;
    // 词边界：后面不能紧跟标识符字符，避免把 `nullable` 当成 `null`
    final end = _index + word.length;
    if (end < _text.length) {
      final next = _text.codeUnitAt(end);
      if (_isIdentifierChar(next)) return false;
    }
    _index = end;
    return true;
  }

  /// 跳过空白与注释。
  ///
  /// 与 Gson lenient 一致支持三种注释：`//` 行注释、`/* */` 块注释、
  /// `#` 行注释（HG / 苹果CMS 等接口用它写分隔行，如 `   ## json   `）。
  void skipTrivia() {
    while (!_atEnd) {
      final char = _current;
      if (char == '#' || (char == '/' && _index + 1 < _text.length &&
          _text[_index + 1] == '/')) {
        _index += char == '#' ? 1 : 2;
        while (!_atEnd && _current != '\n') {
          _index++;
        }
        continue;
      }
      if (_isWhitespace(char)) {
        _index++;
        continue;
      }
      if (char == '/' && _index + 1 < _text.length) {
        if (_text[_index + 1] == '*') {
          _index += 2;
          while (_index + 1 < _text.length &&
              !(_text[_index] == '*' && _text[_index + 1] == '/')) {
            _index++;
          }
          _index = (_index + 2).clamp(0, _text.length);
          continue;
        }
      }
      break;
    }
  }

  static bool _isWhitespace(String char) {
    final code = char.codeUnitAt(0);
    return code == _charSpace ||
        code == _charTab ||
        code == _charLf ||
        code == _charCr ||
        code == _charBom;
  }

  static bool _isDigit(String char) {
    final code = char.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  static bool _isIdentifierChar(int code) {
    return (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A) ||
        code == 0x5F ||
        code > 0x7F;
  }
}
