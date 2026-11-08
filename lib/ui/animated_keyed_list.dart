import 'package:flutter/material.dart';

import 'motion.dart';

/// 按 key 自动比对增删的动画列表：新增项高度展开 + 淡入，删除项收起 + 淡出，
/// 相邻项被平滑推开，而不是瞬间跳动。顺序变化（如会话被顶到最前）直接重排。
///
/// 首次加载的数据不播放动画。
class AnimatedKeyedList<T> extends StatefulWidget {
  const AnimatedKeyedList({
    super.key,
    required this.items,
    required this.keyOf,
    required this.itemBuilder,
    this.reverse = false,
    this.padding,
    this.controller,
    this.physics,
  });

  final List<T> items;
  final Object Function(T item) keyOf;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final bool reverse;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final ScrollPhysics? physics;

  @override
  State<AnimatedKeyedList<T>> createState() => _AnimatedKeyedListState<T>();
}

class _AnimatedKeyedListState<T> extends State<AnimatedKeyedList<T>> {
  final _listKey = GlobalKey<AnimatedListState>();
  late List<T> _items = List.of(widget.items);

  @override
  void didUpdateWidget(covariant AnimatedKeyedList<T> old) {
    super.didUpdateWidget(old);
    final list = _listKey.currentState;
    final next = widget.items;
    if (list == null) {
      _items = List.of(next);
      return;
    }
    final keyOf = widget.keyOf;
    final nextKeys = {for (final i in next) keyOf(i)};

    // 1. 删除：从后往前，播放收起动画。
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (!nextKeys.contains(keyOf(item))) {
        _items.removeAt(i);
        list.removeItem(
          i,
          (context, anim) => _Exit(
            animation: anim,
            axisAlignment: widget.reverse ? 1 : -1,
            child: widget.itemBuilder(context, item),
          ),
          duration: _exitDuration,
        );
      }
    }

    // 2. 新增：按目标位置插入，播放展开动画。
    final currentKeys = {for (final i in _items) keyOf(i)};
    for (var i = 0; i < next.length; i++) {
      final item = next[i];
      if (!currentKeys.contains(keyOf(item))) {
        final at = i.clamp(0, _items.length);
        _items.insert(at, item);
        list.insertItem(at, duration: Motion.medium);
      }
    }

    // 3. 内容更新 / 顺序变化：数量已一致，直接按新顺序重建。
    _items = List.of(next);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedList(
      key: _listKey,
      reverse: widget.reverse,
      padding: widget.padding,
      controller: widget.controller,
      physics: widget.physics,
      initialItemCount: _items.length,
      itemBuilder: (context, index, anim) {
        final item = _items[index];
        return _Enter(
          key: ValueKey(widget.keyOf(item)),
          animation: anim,
          axisAlignment: widget.reverse ? 1 : -1,
          child: widget.itemBuilder(context, item),
        );
      },
    );
  }
}

class _Enter extends StatelessWidget {
  const _Enter({
    super.key,
    required this.animation,
    required this.axisAlignment,
    required this.child,
  });

  final Animation<double> animation;
  final double axisAlignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = animation.drive(CurveTween(curve: Motion.curve));
    return SizeTransition(
      sizeFactor: t,
      alignment: Alignment(0, axisAlignment),
      child: FadeTransition(
        opacity: animation.drive(CurveTween(curve: const Interval(0.15, 1))),
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(t),
          child: child,
        ),
      ),
    );
  }
}

const _exitDuration = Duration(milliseconds: 320);

/// 删除：先淡出并略微缩小（前 55%），高度同时收起，相邻项平滑补位。
class _Exit extends StatelessWidget {
  const _Exit({
    required this.animation,
    required this.axisAlignment,
    required this.child,
  });

  final Animation<double> animation;
  final double axisAlignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // removeItem 的动画从 1 走到 0；曲线都是 0→1 单调不过冲的，可安全用于透明度。
    // drive(CurveTween) 不像 CurvedAnimation 那样向父动画注册监听，build 里创建不泄漏。
    final size = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
    final fade = animation.drive(
      CurveTween(curve: const Interval(0.45, 1, curve: Curves.easeOut)),
    );
    return IgnorePointer(
      child: SizeTransition(
        sizeFactor: size,
        alignment: Alignment(0, axisAlignment),
        child: FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            scale: Tween(begin: 0.94, end: 1.0).animate(fade),
            child: child,
          ),
        ),
      ),
    );
  }
}
