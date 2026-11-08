import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/data/chat_service.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/providers.dart';
import 'package:agent/data/repositories/channel_repository.dart';
import 'package:agent/features/chat/message_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Message _answer(String id, String model, {bool adopted = false}) => Message(
  id: id,
  conversationId: 'c',
  role: 'assistant',
  partsJson: ContentPart.encodeList([TextPart('来自 $model 的回答')]),
  groupId: 'g',
  adopted: adopted,
  modelId: model,
  status: MsgStatus.done,
  createdAt: DateTime(2026),
);

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        modelsProvider.overrideWith(
          (ref) => Stream.value(const <ModelWithRoutes>[]),
        ),
        agentsProvider.overrideWith((ref) => Stream.value(const <Agent>[])),
      ],
      child: MiuixSystemTheme(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnswerGroupView(
                answers: [
                  _answer('1', 'a'),
                  _answer('2', 'b', adopted: true),
                  _answer('3', 'c'),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 卸载并走完 miuix 组件的动画定时器。
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('宽屏：三个回答并排显示，全部可见', (tester) async {
    await _pump(tester, const Size(1400, 900));
    expect(tester.takeException(), isNull);
    for (final m in ['a', 'b', 'c']) {
      expect(find.textContaining('来自 $m 的回答'), findsOneWidget);
    }
    final xs = [
      for (final m in ['a', 'b', 'c'])
        tester.getTopLeft(find.textContaining('来自 $m 的回答')).dx,
    ];
    expect(xs[0] < xs[1] && xs[1] < xs[2], isTrue, reason: '应从左到右排列：$xs');
    expect(find.text('已采纳'), findsOneWidget);
    expect(find.text('采纳'), findsNWidgets(2));
    await _dispose(tester);
  });

  testWidgets('窄屏：标签页切换，默认显示被采纳的回答', (tester) async {
    await _pump(tester, const Size(400, 900));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('来自 b 的回答'), findsOneWidget);
    expect(find.textContaining('来自 a 的回答'), findsNothing);

    // 测试中没有模型记录，标签都显示为「未知模型」；第一个标签对应回答 a。
    await tester.tap(find.text('未知模型').first);
    await tester.pump();
    expect(find.textContaining('来自 a 的回答'), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('接力：按步骤显示，已完成的中间步骤折叠，最终结论展开，未开始的显示等待中', (tester) async {
    Message step(
      int i,
      String status, {
      bool adopted = false,
      String text = '',
    }) => Message(
      id: 's$i',
      conversationId: 'c',
      role: 'assistant',
      partsJson: ContentPart.encodeList([if (text.isNotEmpty) TextPart(text)]),
      groupId: 'g',
      stepIndex: i,
      adopted: adopted,
      modelId: 'm$i',
      status: status,
      createdAt: DateTime(2026),
    );
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelsProvider.overrideWith(
            (ref) => Stream.value(const <ModelWithRoutes>[]),
          ),
          agentsProvider.overrideWith((ref) => Stream.value(const <Agent>[])),
        ],
        child: MiuixSystemTheme(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ChainGroupView(
                  steps: [
                    step(2, MsgStatus.pending),
                    step(0, MsgStatus.done, text: '第一步的完整分析内容'),
                    step(1, MsgStatus.streaming, text: '第二步正在输出'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('分析中…'), findsOneWidget);
    expect(find.text('等待中'), findsOneWidget);
    expect(find.textContaining('1/3'), findsOneWidget);
    // 第一步已完成且不是最终结论：折叠为预览（纯文本），未渲染为 Markdown 正文。
    expect(find.text('第一步的完整分析内容'), findsOneWidget);
    // 第一步在第二步上方。
    expect(
      tester.getTopLeft(find.text('完成')).dy <
          tester.getTopLeft(find.text('分析中…')).dy,
      isTrue,
    );
    await _dispose(tester);
  });
}
