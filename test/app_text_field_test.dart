import 'package:agent/ui/settings_widgets.dart';
import 'package:agent/ui/vendor/app_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MiuixSystemTheme(
  child: MaterialApp(home: Material(child: child)),
);

void main() {
  testWidgets('AppTextField 把 autocorrect / enableSuggestions 透传给 TextField', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AppTextField(
          label: 'x',
          autocorrect: false,
          enableSuggestions: false,
        ),
      ),
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });

  testWidgets('SettingsField 默认关闭纠错（URL / Key / 模型名不能被系统改写）', (tester) async {
    final c = TextEditingController();
    await tester.pumpWidget(
      _wrap(SettingsField(controller: c, label: 'Base URL')),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).autocorrect,
      isFalse,
    );
  });

  testWidgets('密码框总是关闭纠错和建议', (tester) async {
    await tester.pumpWidget(
      _wrap(const AppTextField(label: 'k', obscureText: true)),
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });
}
