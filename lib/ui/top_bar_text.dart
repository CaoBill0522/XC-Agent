import 'package:flutter/widgets.dart';

/// miuix 顶栏用 TextPainter 按标题样式本身（不含行高）测出文字高度并据此裁剪，
/// 但顶栏内部包了一层 Material，Text 会继承 textTheme.bodyMedium 的 M3 行高 1.43
/// （来自 Typography，无法通过 textTheme 去掉），字形被行距往下推，
/// 「Agent」的 g 这类下伸部分就被裁掉了。
/// 顶栏标题都是单行：让行高不作用于首行上方和末行下方，渲染高度即和测量一致。
class TopBarTextFix extends StatelessWidget {
  const TopBarTextFix({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextHeightBehavior(
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
      child: child,
    );
  }
}
