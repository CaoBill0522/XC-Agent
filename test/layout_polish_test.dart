import 'package:agent/ui/app_icons.dart';
import 'package:agent/features/chat/chat_page.dart';
import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/data/chat_service.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/providers.dart';
import 'package:agent/data/repositories/channel_repository.dart';
import 'package:agent/features/chat/input_bar.dart';
import 'package:agent/features/chat/markdown_view.dart';
import 'package:agent/features/chat/message_views.dart';
import 'package:agent/ui/dialogs.dart';
import 'package:agent/ui/top_bar_text.dart';
import 'package:agent/ui/vendor/app_text_field.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 和截图里出问题的回答类似：标题 + 列表 + 行内/块级公式 + 代码。
const _longAnswer = '''
为什么课堂会这么用：

- 在最简单的假设下（忽略死亡、迁移），r 确实可以近似理解为"每个个体单位时间产生的后代数"，所以叫 offspring rate 是有直觉依据的简化。
- 更准确的术语是 **per capita growth rate**（人均增长率）或 **intrinsic rate of natural increase**，等于出生率减死亡率（b − d）。

## 完整结论

这张白板的核心是**演示如何把现实问题规范地写成初值问题**：

\$\$\\frac{dP}{dt} = rP, \\quad P(0) = P_0, \\quad r > 0, \\quad \\text{一个很长很长很长很长很长很长很长很长很长的公式说明}\$\$

方程描述变化规律，解为 \$P(t) = P_0 e^{rt}\$。

```python
print("a very long line of code that should scroll horizontally instead of overflowing the card")
```
''';

Widget _app(Widget child) => ProviderScope(
  overrides: [
    modelsProvider.overrideWith(
      (ref) => Stream.value(const <ModelWithRoutes>[]),
    ),
    agentsProvider.overrideWith((ref) => Stream.value(const <Agent>[])),
    conversationProvider.overrideWith((ref, id) => null),
  ],
  child: MiuixTheme(
    data: MiuixThemeData.of(Brightness.dark),
    child: MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: child),
    ),
  ),
);

Message _step(int i, {bool adopted = false}) => Message(
  id: 's$i',
  conversationId: 'c',
  role: 'assistant',
  partsJson: ContentPart.encodeList([const TextPart(_longAnswer)]),
  groupId: 'g',
  stepIndex: i,
  adopted: adopted,
  modelId: 'm$i',
  status: MsgStatus.done,
  usageJson: '{"output":1773}',
  createdAt: DateTime(2026),
);

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('接力卡片：长内容（标题/公式/代码）不溢出，操作按钮完整位于卡片内部', (tester) async {
    await _setSize(tester, const Size(440, 3000));
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ChainGroupView(steps: [_step(0), _step(1, adopted: true)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '不应出现 RenderFlex overflow');

    // 最终结论（已采纳）默认展开：其操作行必须在卡片矩形内部。
    final card = find.byType(HighlightCard).last;
    final cardRect = tester.getRect(card);
    final tokens = find.descendant(
      of: card,
      matching: find.text('1773 tokens'),
    );
    expect(tokens, findsOneWidget);
    final tokensRect = tester.getRect(tokens);
    expect(
      tokensRect.bottom <= cardRect.bottom - 4,
      isTrue,
      reason: '操作行 $tokensRect 应完整位于卡片 $cardRect 内，不能压在边框上',
    );
    expect(cardRect.right <= 440 - 16 + 0.5, isTrue, reason: '卡片不能超出右侧留白');
    await _dispose(tester);
  });

  testWidgets('深色模式：Markdown 标题使用 miuix 的前景色，不会和背景同色', (tester) async {
    await _setSize(tester, const Size(440, 1400));
    await tester.pumpWidget(_app(const MarkdownView('## 完整结论\n\n正文')));
    await tester.pump();
    final expected = MiuixThemeData.of(Brightness.dark).colors.onSurface;
    final heading = find.byWidgetPredicate((w) {
      if (w is! RichText) return false;
      return w.text.toPlainText().contains('完整结论');
    });
    expect(heading, findsWidgets);
    final rich = tester.widget<RichText>(heading.first);
    Color? colorOf(InlineSpan span) {
      Color? found = span.style?.color;
      span.visitChildren((c) {
        if (c is TextSpan && (c.text ?? '').contains('完整')) {
          found = c.style?.color ?? found;
        }
        return true;
      });
      return found;
    }

    expect(colorOf(rich.text), expected);
    await _dispose(tester);
  });

  testWidgets('输入栏：输入框与按钮等高，左侧图标、右侧发送键分别对齐内容左右边缘', (tester) async {
    await _setSize(tester, const Size(440, 800));
    final controller = InputBarController();
    await tester.pumpWidget(
      _app(
        Align(
          alignment: Alignment.bottomCenter,
          child: ChatInputBar(
            conversationId: 'c',
            controller: controller,
            generating: false,
            webSearchSupported: true,
            hasParticipants: true,
            onError: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    final field = tester.getRect(find.byType(AppTextField));
    final buttons = find.byType(MiuixIconButton);
    expect(buttons, findsNWidgets(3));
    final first = tester.getRect(buttons.first);
    final send = tester.getRect(buttons.last);

    expect(
      (field.height - send.height).abs() < 1,
      isTrue,
      reason: '单行输入框高 ${field.height}，按钮高 ${send.height}，应一致',
    );
    expect((field.center.dy - send.center.dy).abs() < 1, isTrue);
    expect((field.center.dy - first.center.dy).abs() < 1, isTrue);
    // 消息列表左右留白 16：发送键右边缘 = 440 - 16；左侧图标（24）的左边缘 = 16。
    expect(
      (send.right - (440 - 16)).abs() < 0.5,
      isTrue,
      reason: 'send.right=${send.right}',
    );
    expect(
      (first.center.dx - 12 - 16).abs() < 0.5,
      isTrue,
      reason: 'first=$first',
    );
    await _dispose(tester);
    controller.dispose();
  });

  // 回归：首页大标题「Agent」的 g 下半截被裁掉（Text 继承了 Material 的 1.43 行高，
  // 比 miuix 测量用的高度高）。
  testWidgets('顶栏大标题：文字不超出裁剪区域', (tester) async {
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.of(Brightness.light),
        child: MaterialApp(
          home: MiuixScaffold(
            topBar: TopBarTextFix(child: MiuixTopAppBar(title: 'Agent')),
            content: (p) => const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final e = find.text('Agent').evaluate().first;
    final para = e.renderObject! as RenderParagraph;
    final clip = e.findAncestorRenderObjectOfType<RenderClipRect>()!;
    expect(para.size.height, lessThanOrEqualTo(clip.size.height));
  });

  testWidgets('长按菜单：深色卡片左、右、下边距相等', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.of(Brightness.dark),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Center(
              child: GestureDetector(
                onTap: () => showActionSheet(
                  context,
                  title: '标题',
                  actions: [SheetAction('删除', () {})],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(MiuixCard));
    const screen = Size(402, 874);
    expect(
      card.left,
      moreOrLessEquals(screen.width - card.right, epsilon: 0.5),
    );
    expect(
      screen.height - card.bottom,
      moreOrLessEquals(card.left, epsilon: 0.5),
    );
  });

  testWidgets('聊天页顶栏：长标题不压住两侧按钮', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final conv = Conversation(
      id: 'c',
      title: '用几条要点总结下面的内容，每条一句话，这是一个很长很长的标题',
      mode: 'single',
      agentIdsJson: '[]',
      participantsJson: '[{"modelId":"m"}]',
      webSearch: false,
      optionsJson: '{}',
      pinned: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelsProvider.overrideWith(
            (ref) => Stream.value(const <ModelWithRoutes>[]),
          ),
          agentsProvider.overrideWith((ref) => Stream.value(const <Agent>[])),
          conversationProvider.overrideWith((ref, id) => conv),
          messagesProvider.overrideWith(
            (ref, id) => Stream.value([
              Message(
                id: 'u',
                conversationId: 'c',
                role: 'user',
                partsJson: '[{"type":"text","text":"hi"}]',
                adopted: true,
                status: 'done',
                createdAt: DateTime(2026),
              ),
            ]),
          ),
        ],
        child: MiuixTheme(
          data: MiuixThemeData.of(Brightness.light),
          child: const MaterialApp(home: ChatPage(conversationId: 'c')),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final title = tester.getRect(find.textContaining('用几条要点'));
    var checked = 0;
    for (final b in find.byType(AppIconButton).evaluate()) {
      final r = tester.getRect(find.byWidget(b.widget));
      if (r.top > 120) continue; // 只看顶栏里的按钮
      checked++;
      expect(title.overlaps(r), isFalse, reason: 'title=$title button=$r');
    }
    expect(checked, 3, reason: '返回、分享、设置三个按钮');
  });
}
