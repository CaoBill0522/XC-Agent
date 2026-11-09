import 'dart:math' as math;

import '../../l10n/tr.dart';

/// 计算器工具用的四则运算解析器：+ - * / % ^、括号、常用函数和常量。
/// 只做数学运算，不执行任何代码。
double evaluateExpression(String input) => _Parser(input).parse();

class _Parser {
  _Parser(String input)
    : _s = input
          .replaceAll('×', '*')
          .replaceAll('÷', '/')
          .replaceAll('**', '^')
          .replaceAll('（', '(')
          .replaceAll('）', ')')
          .replaceAll(RegExp(r'\s+'), '');

  final String _s;
  int _i = 0;

  double parse() {
    if (_s.isEmpty) throw FormatException(tr('表达式为空'));
    final v = _expr();
    if (_i < _s.length) {
      throw FormatException(trArgs('无法识别「{0}」', [_s.substring(_i)]));
    }
    return v;
  }

  bool _eat(String c) {
    if (_i < _s.length && _s[_i] == c) {
      _i++;
      return true;
    }
    return false;
  }

  double _expr() {
    var v = _term();
    while (true) {
      if (_eat('+')) {
        v += _term();
      } else if (_eat('-')) {
        v -= _term();
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _unary();
    while (true) {
      if (_eat('*')) {
        v *= _unary();
      } else if (_eat('/')) {
        v /= _unary();
      } else if (_eat('%')) {
        v %= _unary();
      } else {
        return v;
      }
    }
  }

  // 负号优先级低于乘方：-2^2 = -4。
  double _unary() {
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _power();
  }

  // 乘方右结合：2^3^2 = 2^9；指数可以带负号：2^-1。
  double _power() {
    final base = _factorial(_atom());
    if (_eat('^')) return math.pow(base, _unary()).toDouble();
    return base;
  }

  double _factorial(double v) {
    while (_eat('!')) {
      if (v < 0 || v != v.roundToDouble() || v > 170) {
        throw FormatException(tr('阶乘只支持 0~170 的整数'));
      }
      var r = 1.0;
      for (var k = 2; k <= v; k++) {
        r *= k;
      }
      v = r;
    }
    return v;
  }

  static final _number = RegExp(r'\d+(\.\d*)?([eE][+-]?\d+)?|\.\d+');
  static final _name = RegExp(r'[a-zA-Z_]+');

  double _atom() {
    if (_eat('(')) {
      final v = _expr();
      if (!_eat(')')) throw FormatException(tr('括号不匹配'));
      return v;
    }
    if (_number.matchAsPrefix(_s, _i) case final m?) {
      _i = m.end;
      return double.parse(m[0]!);
    }
    if (_name.matchAsPrefix(_s, _i) case final m?) {
      _i = m.end;
      final name = m[0]!.toLowerCase();
      switch (name) {
        case 'pi':
          return math.pi;
        case 'e':
          return math.e;
      }
      if (!_eat('(')) throw FormatException(trArgs('未知名称「{0}」', [name]));
      final args = <double>[_expr()];
      while (_eat(',')) {
        args.add(_expr());
      }
      if (!_eat(')')) throw FormatException(tr('括号不匹配'));
      return _call(name, args);
    }
    throw FormatException(
      _i < _s.length ? trArgs('无法识别「{0}」', [_s.substring(_i)]) : tr('表达式不完整'),
    );
  }

  static double _call(String name, List<double> a) {
    double one() {
      if (a.length != 1) throw FormatException(trArgs('{0} 需要 1 个参数', [name]));
      return a.first;
    }

    return switch (name) {
      'sqrt' => math.sqrt(one()),
      'abs' => one().abs(),
      'sin' => math.sin(one()),
      'cos' => math.cos(one()),
      'tan' => math.tan(one()),
      'asin' => math.asin(one()),
      'acos' => math.acos(one()),
      'atan' => math.atan(one()),
      'ln' => math.log(one()),
      'log' || 'log10' => math.log(one()) / math.ln10,
      'log2' => math.log(one()) / math.ln2,
      'exp' => math.exp(one()),
      'floor' => one().floorToDouble(),
      'ceil' => one().ceilToDouble(),
      'round' => one().roundToDouble(),
      'pow' when a.length == 2 => math.pow(a[0], a[1]).toDouble(),
      'min' when a.isNotEmpty => a.reduce(math.min),
      'max' when a.isNotEmpty => a.reduce(math.max),
      _ => throw FormatException(trArgs('不支持的函数「{0}」', [name])),
    };
  }
}

/// 计算结果格式化：整数不带小数点，其余最多 12 位有效数字。
String formatNumber(double v) {
  if (v.isNaN) return tr('NaN（无意义的结果）');
  if (v.isInfinite) return v > 0 ? '∞' : '-∞';
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  final s = v.toStringAsPrecision(12);
  return s.contains('e')
      ? s
      : s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
