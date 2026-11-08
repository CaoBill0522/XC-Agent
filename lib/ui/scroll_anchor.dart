import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 倒序（聊天）列表里展开 / 收起某一项时，让该项「顶部不动、只往下伸缩」。
///
/// 倒序列表以底部为基准排版，某项变高时它的顶部会被往上顶，看起来整块内容
/// 在往上跳。这里在「同一帧」内抵消：
/// 1. [AnchorTop] 在排版时记下自己这一帧的高度变化；
/// 2. 列表随后更新内容总高度时，[AnchoredScrollPhysics] 把滚动位置平移同样的量；
/// 3. 位置变了，视口会在同一帧内重新排版一次，然后才绘制。
/// 因此没有「先跳一下再拉回来」的一帧延迟，展开动画不会有撕裂感。
class ScrollAnchor {
  double _pending = 0;
  bool _resetScheduled = false;

  void _add(double delta) {
    _pending += delta;
    if (_resetScheduled) return;
    _resetScheduled = true;
    // 本帧没被消费（如内容不足一屏、无法滚动）就丢弃，不留到以后误用。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = 0;
      _resetScheduled = false;
    });
  }

  double _take() {
    final d = _pending;
    _pending = 0;
    return d;
  }
}

class ScrollAnchorScope extends InheritedWidget {
  const ScrollAnchorScope({
    super.key,
    required this.anchor,
    required super.child,
  });

  final ScrollAnchor anchor;

  static ScrollAnchor? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScrollAnchorScope>()?.anchor;

  @override
  bool updateShouldNotify(ScrollAnchorScope old) => old.anchor != anchor;
}

class AnchoredScrollPhysics extends ScrollPhysics {
  const AnchoredScrollPhysics({required this.anchor, super.parent});

  final ScrollAnchor anchor;

  @override
  AnchoredScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      AnchoredScrollPhysics(anchor: anchor, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final base = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    final delta = anchor._take();
    // 只有倒序列表需要：正序列表里内容本来就是往下伸展的。
    if (delta == 0 || !axisDirectionIsReversed(newPosition.axisDirection)) {
      return base;
    }
    // 倒序列表 pixels 增大 = 内容下移，正好抵消该项顶部被顶上去的距离。
    // 以「原位置」为基准，不能叠加在 base 上：列表滚到最顶端时，内容变短
    // 会让父级 physics 已经把位置按新的 maxScrollExtent 钳回一次，再减一次
    // 就重复了（收起时页面整体往上跑一下）。
    // 已在最底部时没法再往下：只钳最小值（内容随动画平滑下移，不会跳）。
    return math.max(newPosition.minScrollExtent, newPosition.pixels + delta);
  }
}

/// 包住会展开 / 收起的内容。[active] 为 true 期间，它的高度变化会被
/// 所在列表抵消（需要列表使用 [AnchoredScrollPhysics] 并提供 [ScrollAnchorScope]）。
class AnchorTop extends SingleChildRenderObjectWidget {
  const AnchorTop({super.key, required this.active, super.child});

  final bool active;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderAnchorTop(
    anchor: ScrollAnchorScope.maybeOf(context),
    active: active,
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderAnchorTop)
      ..anchor = ScrollAnchorScope.maybeOf(context)
      ..active = active;
  }
}

class _RenderAnchorTop extends RenderProxyBox {
  _RenderAnchorTop({required this.anchor, required this.active});

  ScrollAnchor? anchor;
  bool active;
  double? _lastHeight;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    final last = _lastHeight;
    _lastHeight = h;
    if (active && last != null && (h - last).abs() > 0.01) {
      anchor?._add(h - last);
    }
  }
}
