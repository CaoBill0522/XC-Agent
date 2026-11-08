import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_miuix/miuix.dart';

/// 把 miuix（Folme）的弹簧参数转换成 Curve，供 Flutter 隐式动画使用。
///
/// 弹簧动画前段快、尾段柔和收敛，比固定时长的缓动曲线更接近 HyperOS 的手感。
/// [duration] 是弹簧基本静止（误差 < 0.4%）所需的时间，配套用于动画时长。
class SpringCurve extends Curve {
  SpringCurve({required double damping, required double response})
    : _overshoots = damping < 1,
      _sim = SpringSimulation(
        folmeSpring(damping: damping, response: response),
        0,
        1,
        0,
      ) {
    _seconds = _settle(_sim);
  }

  final SpringSimulation _sim;
  final bool _overshoots;
  late final double _seconds;

  Duration get duration => Duration(milliseconds: (_seconds * 1000).round());

  static double _settle(SpringSimulation sim) {
    var last = 0.0;
    for (var t = 0.0; t < 3.0; t += 0.004) {
      if ((sim.x(t) - 1).abs() > 0.004) last = t;
    }
    return math.max(last + 0.004, 0.05);
  }

  @override
  double transformInternal(double t) => sim(t);

  double sim(double t) {
    if (t >= 1) return 1;
    final v = _sim.x(t * _seconds);
    // 只有欠阻尼（回弹）曲线允许超出 1；其余夹紧，可以安全用于透明度。
    return _overshoots ? v : v.clamp(0.0, 1.0);
  }
}

/// 全局统一的动效参数，保证各处动画节奏一致。
abstract final class Motion {
  /// 小元素状态切换（颜色、按钮互换）：临界阻尼，响应快。
  static final fastSpring = SpringCurve(damping: 1.0, response: 0.26);

  /// 展开 / 收起、内容切换、列表增删：临界阻尼，无过冲。
  static final spring = SpringCurve(damping: 1.0, response: 0.36);

  /// 轻微回弹，用于弹出式出现（发送键、状态标签）。
  static final bouncy = SpringCurve(damping: 0.78, response: 0.34);

  static Duration get fast => fastSpring.duration;
  static Duration get medium => spring.duration;
  static Duration get pop => bouncy.duration;

  static Curve get curve => spring;

  /// 退场用的短缓入（退场应比进场更快、更干脆）。
  static const exit = Curves.easeInCubic;
  static const exitDuration = Duration(milliseconds: 140);
}

/// 展开 / 收起：高度平滑过渡，内容淡入淡出。
class AppExpand extends StatelessWidget {
  const AppExpand({super.key, required this.expanded, required this.child});

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSize(
        duration: Motion.medium,
        curve: Motion.curve,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: Motion.fast,
          reverseDuration: Motion.exitDuration,
          switchInCurve: Motion.fastSpring,
          switchOutCurve: Motion.exit,
          // 收起时不让旧内容撑住高度。
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            children: [
              for (final p in previous)
                Positioned(left: 0, right: 0, top: 0, child: p),
              ?current,
            ],
          ),
          child: expanded
              ? KeyedSubtree(key: const ValueKey(true), child: child)
              : const SizedBox(key: ValueKey(false), width: double.infinity),
        ),
      ),
    );
  }
}

/// 内容替换：淡入 + 轻微上移，高度平滑变化。[switchKey] 变化时触发。
class FadeSwitch extends StatelessWidget {
  const FadeSwitch({
    super.key,
    required this.switchKey,
    required this.child,
    this.alignment = Alignment.topLeft,
    this.animateSize = true,
  });

  final Object? switchKey;
  final Widget child;
  final Alignment alignment;
  final bool animateSize;

  static Widget _transition(Widget child, Animation<double> anim) =>
      FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.015),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final switcher = AnimatedSwitcher(
      duration: Motion.medium,
      reverseDuration: Motion.exitDuration,
      switchInCurve: Motion.curve,
      switchOutCurve: Motion.exit,
      transitionBuilder: _transition,
      // 整页切换（animateSize: false）时新旧页面都铺满区域；
      // 按内容高度切换时旧内容贴顶，不撑住高度。
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        // passthrough：整页时父级是紧约束（铺满），按钮等内容尺寸场景时是松约束。
        fit: animateSize ? StackFit.loose : StackFit.passthrough,
        children: [
          for (final p in previous)
            animateSize
                ? Positioned(left: 0, right: 0, top: 0, child: p)
                : Positioned.fill(child: p),
          ?current,
        ],
      ),
      child: KeyedSubtree(key: ValueKey(switchKey), child: child),
    );
    if (!animateSize) return switcher;
    return AnimatedSize(
      duration: Motion.medium,
      curve: Motion.curve,
      alignment: alignment,
      child: switcher,
    );
  }
}

/// 小部件互换（发送 ↔ 停止、状态文字）：带轻微回弹的缩放 + 淡入。
class PopSwitch extends StatelessWidget {
  const PopSwitch({super.key, required this.switchKey, required this.child});

  final Object? switchKey;
  final Widget child;

  // 必须是静态函数：闭包每次 build 都是新对象，AnimatedSwitcher 会因此对每个子项
  // 重跑 transitionBuilder，而 CurvedAnimation 每次创建都会向控制器注册一个监听，
  // 流式输出时每 80ms 重建一次，监听越积越多。
  static Widget _transition(Widget child, Animation<double> anim) =>
      FadeTransition(
        opacity: CurvedAnimation(
          parent: anim,
          curve: const Interval(0, 0.4),
          reverseCurve: Curves.easeIn,
        ),
        child: ScaleTransition(
          scale: Tween(begin: 0.7, end: 1.0).animate(
            CurvedAnimation(
              parent: anim,
              curve: Motion.bouncy,
              reverseCurve: Motion.exit,
            ),
          ),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    // 注意：回弹曲线会略超过 1。AnimatedSwitcher 本身保持线性，只让缩放用回弹曲线；
    // 透明度用线性值做 Interval（Interval 只接受 0~1，喂入回弹值会断言失败卡死渲染）。
    return AnimatedSwitcher(
      duration: Motion.pop,
      reverseDuration: Motion.exitDuration,
      transitionBuilder: _transition,
      child: KeyedSubtree(key: ValueKey(switchKey), child: child),
    );
  }
}

/// 首次出现：高度从 0 展开（周围内容被平滑推开，而不是瞬间跳动），同时淡入上移。
/// [animate] 为 false 时直接显示。
class AppearIn extends StatefulWidget {
  const AppearIn({
    super.key,
    required this.child,
    this.animate = true,
    this.axisAlignment = 1.0,
  });

  final Widget child;
  final bool animate;

  /// 展开时内容锚定的位置：1 = 底部（适合从底部长出的聊天列表），-1 = 顶部。
  final double axisAlignment;

  @override
  State<AppearIn> createState() => _AppearInState();
}

class _AppearInState extends State<AppearIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.medium,
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Motion.curve,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _t,
      alignment: Alignment(0, widget.axisAlignment),
      child: FadeTransition(
        opacity: _c.drive(CurveTween(curve: const Interval(0.15, 1))),
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(_t),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 带 HyperOS 按压下沉反馈的点击区域（替代裸 GestureDetector）。
class Tap extends StatelessWidget {
  const Tap({
    super.key,
    required this.onTap,
    required this.child,
    this.sink = true,
    this.cornerRadius = 10,
    this.semanticLabel,
  });

  final VoidCallback? onTap;
  final Widget child;

  /// 是否缩放下沉。整行等大面积区域只显示按压遮罩，不缩放。
  final bool sink;
  final double cornerRadius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return MiuixPressable(
      onPressed: onTap,
      feedbackType: sink
          ? MiuixPressFeedbackType.sink
          : MiuixPressFeedbackType.none,
      sinkAmount: 0.9,
      shape: MiuixSquircleBorder(cornerRadius: cornerRadius),
      semanticLabel: semanticLabel,
      child: child,
    );
  }
}

/// 统一的页面路由：所有平台都用右侧滑入（与 HyperOS / iOS 一致），支持边缘右滑返回。
Route<T> appRoute<T>(Widget page) => MaterialPageRoute<T>(builder: (_) => page);

/// 淡入的全屏覆盖层路由（图片查看等）。
Route<T> fadeRoute<T>(Widget page) => PageRouteBuilder<T>(
  opaque: false,
  transitionDuration: Motion.medium,
  reverseTransitionDuration: Motion.exitDuration * 1.5,
  pageBuilder: (_, _, _) => page,
  transitionsBuilder: (_, anim, _, child) => FadeTransition(
    opacity: CurvedAnimation(
      parent: anim,
      curve: Motion.fastSpring,
      reverseCurve: Motion.exit,
    ),
    child: ScaleTransition(
      scale: Tween(begin: 0.94, end: 1.0).animate(
        CurvedAnimation(
          parent: anim,
          curve: Motion.curve,
          reverseCurve: Motion.exit,
        ),
      ),
      child: child,
    ),
  ),
);
