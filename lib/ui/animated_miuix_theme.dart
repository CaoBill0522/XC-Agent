import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart';

import 'miuix_colors_lerp.dart';
import 'motion.dart';

/// 深色 / 浅色 / 主题色切换时，整套 miuix 配色平滑过渡，而不是瞬间跳变。
/// 放在 MiuixThemeController 之下，读取其给出的目标主题。
class AnimatedMiuixTheme extends StatefulWidget {
  const AnimatedMiuixTheme({super.key, required this.child});

  final Widget child;

  @override
  State<AnimatedMiuixTheme> createState() => _AnimatedMiuixThemeState();
}

class _AnimatedMiuixThemeState extends State<AnimatedMiuixTheme>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.medium,
    value: 1,
  );
  MiuixColors? _from;
  MiuixColors? _to;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final target = MiuixTheme.of(context).colors;
    if (_to == null) {
      _to = target;
    } else if (target != _to) {
      _from = _current;
      _to = target;
      _c.forward(from: 0);
    }
  }

  MiuixColors get _current {
    final from = _from;
    if (from == null || _c.value >= 1) return _to!;
    return lerpMiuixColors(from, _to!, Motion.curve.transform(_c.value));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = MiuixTheme.of(context);
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => MiuixTheme(
        data: data.copyWith(colors: _current),
        child: child!,
      ),
    );
  }
}
