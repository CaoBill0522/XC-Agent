import 'package:agent/ui/layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('底部占用高度：键盘收起过程中不会先低于安全区再跳回', (tester) async {
    // iPhone 底部安全区 34；键盘收起时 viewInsets 从 336 一路降到 0。
    final seen = <double>[];
    for (final keyboard in <double>[336, 200, 60, 20, 5, 0]) {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            viewPadding: const EdgeInsets.only(bottom: 34),
            // Flutter 在键盘弹出时把 padding 扣掉键盘高度。
            padding: EdgeInsets.only(bottom: (34 - keyboard).clamp(0.0, 34.0)),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: Builder(
            builder: (context) {
              seen.add(bottomInsetOf(context));
              return const SizedBox();
            },
          ),
        ),
      );
    }
    expect(seen, [336, 200, 60, 34, 34, 34]);
    // 单调不增：输入栏只会往下走，不会掉到底再弹回。
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], lessThanOrEqualTo(seen[i - 1]));
    }
  });
}
