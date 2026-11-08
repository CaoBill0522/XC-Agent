import 'package:agent/ui/scroll_anchor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Item extends StatefulWidget {
  const _Item({required this.anchored});
  final bool anchored;
  @override
  State<_Item> createState() => _ItemState();
}

class _ItemState extends State<_Item> {
  bool open = false;
  @override
  Widget build(BuildContext context) => AnchorTop(
    active: widget.anchored,
    child: GestureDetector(
      onTap: () => setState(() => open = !open),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 400),
        alignment: Alignment.topCenter,
        child: Container(
          key: const ValueKey('target'),
          height: open ? 500 : 60,
          color: Colors.blue,
        ),
      ),
    ),
  );
}

Widget _app({required bool anchored}) {
  final anchor = ScrollAnchor();
  return MaterialApp(
    home: Scaffold(
      body: ScrollAnchorScope(
        anchor: anchor,
        child: ListView(
          reverse: true,
          physics: AnchoredScrollPhysics(anchor: anchor),
          children: [
            for (var i = 0; i < 4; i++)
              SizedBox(height: 100, child: Text('a$i')),
            _Item(anchored: anchored),
            for (var i = 0; i < 10; i++)
              SizedBox(height: 100, child: Text('b$i')),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {});
  for (final anchored in [true, false]) {
    testWidgets('倒序列表展开：anchored=$anchored 时顶部${anchored ? '不动' : '被顶上去'}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(anchored: anchored));
      final target = find.byKey(const ValueKey('target'));
      final top = tester.getTopLeft(target).dy;
      await tester.tap(target);
      var maxDrift = 0.0;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final d = (tester.getTopLeft(target).dy - top).abs();
        if (d > maxDrift) maxDrift = d;
      }
      expect(tester.getSize(target).height, 500);
      if (anchored) {
        expect(maxDrift, lessThan(0.5));
        // 收起同样顶部不动。
        await tester.tap(target);
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.getTopLeft(target).dy,
            moreOrLessEquals(top, epsilon: 0.5),
          );
        }
      } else {
        expect(maxDrift, greaterThan(100), reason: '对照：不处理时顶部会被顶上去');
      }
      expect(tester.takeException(), isNull);
    });
  }
}
