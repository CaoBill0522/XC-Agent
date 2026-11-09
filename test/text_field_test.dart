import 'package:agent/ui/vendor/app_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('占位文字：输入内容后立刻消失（父组件不重建时也一样）', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.of(Brightness.light),
        child: MaterialApp(
          home: Scaffold(
            body: AppTextField(
              controller: controller,
              label: '例如：你是一名专业的中英翻译……',
              useLabelAsPlaceholder: true,
              minLines: 4,
              maxLines: 14,
            ),
          ),
        ),
      ),
    );
    expect(find.text('例如：你是一名专业的中英翻译……'), findsOneWidget);
    // 先点进输入框，等聚焦动画结束，再打字（真机上的顺序）。
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '你是翻译');
    await tester.pump();
    expect(find.text('例如：你是一名专业的中英翻译……'), findsNothing);
    controller.clear();
    await tester.pump();
    expect(find.text('例如：你是一名专业的中英翻译……'), findsOneWidget);
  });
}
