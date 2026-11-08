import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 子组件尺寸变化时回调（布局完成后的下一帧触发）。
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({super.key, required this.onChange, super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderMeasureSize(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMeasureSize renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class RenderMeasureSize extends RenderProxyBox {
  RenderMeasureSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    final s = child?.size ?? Size.zero;
    if (s == _last) return;
    _last = s;
    // 页面关闭后不再回调（回调的目标可能已被 dispose）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onChange(s);
    });
  }
}

/// 让 Snackbar 浮在页面底部操作区（输入栏、保存按钮）之上，而不是盖住它们。
///
/// miuix 只会把 Snackbar 放在脚手架 bottomBar 之上；我们的输入栏在内容区里，
/// 所以用 [bottomOccupied]（底部操作区的实测高度，含键盘 / 安全区）把它往上抬。
class SnackbarAbove extends StatelessWidget {
  const SnackbarAbove({
    super.key,
    required this.bottomOccupied,
    required this.child,
  });

  final ValueListenable<double> bottomOccupied;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return ValueListenableBuilder<double>(
      valueListenable: bottomOccupied,
      builder: (context, h, child) => Padding(
        padding: EdgeInsets.only(
          bottom: (h - safeBottom).clamp(0, double.infinity),
        ),
        child: child,
      ),
      child: child,
    );
  }
}
