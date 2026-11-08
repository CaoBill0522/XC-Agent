import 'dart:async';

import 'package:agent/core/api/api_error.dart';
import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/ui/links.dart';
import 'package:agent/data/chat_service.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/features/chat/follow_up.dart';
import 'package:agent/features/chat/message_views.dart';
import 'package:agent/data/providers.dart';
import 'package:agent/data/repositories/channel_repository.dart';
import 'package:agent/features/chat/input_bar.dart';
import 'package:agent/ui/animated_keyed_list.dart';
import 'package:agent/ui/measure_size.dart';
import 'package:agent/ui/miuix_colors_lerp.dart';
import 'package:agent/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChat implements ChatService {
  final sent = <String>[];

  @override
  Future<void> send(
    String convId,
    String text, {
    List<PendingImage> images = const [],
    String? quote,
    String? context,
  }) async {
    if (fail) throw ApiException('请先选择模型');
    sent.add(text);
    quotes.add(quote);
  }

  bool fail = false;

  final quotes = <String?>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _list(List<String> items) => MaterialApp(
  home: Scaffold(
    body: AnimatedKeyedList<String>(
      items: items,
      keyOf: (s) => s,
      itemBuilder: (context, s) => SizedBox(height: 50, child: Text(s)),
    ),
  ),
);

void main() {
  test('弹簧曲线：从 0 到 1，临界阻尼单调不过冲，前段快后段缓', () {
    final c = Motion.spring;
    expect(c.transform(0), 0);
    expect(c.transform(1), 1);
    var prev = 0.0;
    for (var i = 1; i <= 100; i++) {
      final v = c.transform(i / 100);
      expect(v >= prev - 1e-9, isTrue, reason: '应单调');
      expect(v <= 1.0001, isTrue, reason: '临界阻尼不应过冲');
      prev = v;
    }
    expect(c.transform(0.25) > 0.5, isTrue, reason: '前 1/4 时间应完成过半');
    expect(Motion.bouncy.transform(0.75) > 1, isTrue, reason: '回弹曲线有轻微过冲');
  });

  test('配色插值：端点等于原配色，中点介于两者之间', () {
    final a = lightColorScheme();
    final b = darkColorScheme();
    expect(lerpMiuixColors(a, b, 0), a);
    expect(lerpMiuixColors(a, b, 1), b);
    final mid = lerpMiuixColors(a, b, 0.5).surface;
    expect(mid, isNot(a.surface));
    expect(mid, isNot(b.surface));
  });

  testWidgets('动画列表：新增项高度从 0 展开，删除项先收起再移除，相邻项不瞬间跳动', (tester) async {
    await tester.pumpWidget(_list(['a', 'b']));
    // 初始数据不播放动画。
    expect(tester.getSize(find.text('a')).height, 50);

    await tester.pumpWidget(_list(['new', 'a', 'b']));
    await tester.pump(const Duration(milliseconds: 16));
    final growing = tester.getTopLeft(find.text('a')).dy;
    expect(
      growing > 0 && growing < 50,
      isTrue,
      reason: '新增项正在展开，a 被逐步推下：$growing',
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('a')).dy, 50);

    await tester.pumpWidget(_list(['new', 'b']));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('a'), findsOneWidget, reason: '删除动画期间仍在');
    await tester.pumpAndSettle();
    expect(find.text('a'), findsNothing);
    expect(tester.getTopLeft(find.text('b')).dy, 50);

    // 重新排序：数量不变，直接按新顺序显示。
    await tester.pumpWidget(_list(['b', 'new']));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('b')).dy, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Snackbar 抬高：底部占用高度扣除安全区后作为下边距', (tester) async {
    final occupied = ValueNotifier<double>(90);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(bottom: 34)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SnackbarAbove(
            bottomOccupied: occupied,
            child: const SizedBox(height: 10),
          ),
        ),
      ),
    );
    Padding pad() => tester.widget<Padding>(
      find.descendant(
        of: find.byType(SnackbarAbove),
        matching: find.byType(Padding),
      ),
    );
    expect(pad().padding, const EdgeInsets.only(bottom: 56));
    occupied.value = 20;
    await tester.pump();
    expect(pad().padding, EdgeInsets.zero);
  });

  test('临界阻尼曲线输出夹在 [0,1]，可安全用于透明度', () {
    for (final c in [Motion.spring, Motion.fastSpring]) {
      for (var i = 0; i <= 1000; i++) {
        final v = c.transform(i / 1000);
        expect(v >= 0 && v <= 1, isTrue);
      }
    }
  });

  // 回归：发送 → 停止 → 发送 的按钮切换曾因回弹曲线超出 1 触发断言，
  // debug 构建下整个界面卡死（输入栏消失、点击无响应）。
  testWidgets('输入栏：生成中 ↔ 空闲来回切换不抛异常', (tester) async {
    final c = InputBarController();
    Widget app(bool gen) => ProviderScope(
      overrides: [
        modelsProvider.overrideWith(
          (ref) => Stream.value(const <ModelWithRoutes>[]),
        ),
        agentsProvider.overrideWith((ref) => Stream.value(const <Agent>[])),
        conversationProvider.overrideWith((ref, id) => null),
      ],
      child: MiuixSystemTheme(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatInputBar(
                conversationId: 'c',
                controller: c,
                generating: gen,
                webSearchSupported: true,
                hasParticipants: true,
                onError: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    for (final gen in [false, true, false, true, false]) {
      await tester.pumpWidget(app(gen));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.takeException(), isNull, reason: 'generating=$gen');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    c.dispose();
  });

  testWidgets('发送后收起键盘（手机端）', (tester) async {
    final c = InputBarController();
    final chat = _FakeChat();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatServiceProvider.overrideWithValue(chat),
          conversationProvider.overrideWith((ref, id) => null),
        ],
        child: MiuixSystemTheme(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: ChatInputBar(
                  conversationId: 'c',
                  controller: c,
                  generating: false,
                  webSearchSupported: false,
                  hasParticipants: true,
                  onError: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(EditableText));
    await tester.enterText(find.byType(EditableText), '你好');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(chat.sent, ['你好']);
    expect(tester.testTextInput.isVisible, isFalse, reason: '键盘应已收起');
    c.dispose();
  });

  group('联网来源', () {
    final many = [
      for (var i = 1; i <= 8; i++)
        CitationPart('https://www.site$i.com/a', '标题 $i'),
    ];
    Future<void> pump(
      WidgetTester tester,
      List<CitationPart> cs,
      double width,
    ) => tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.of(Brightness.light),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: width, child: CitationList(cs)),
            ),
          ),
        ),
      ),
    );

    testWidgets('宽度够时每行 3 个，最多两行，放不下时最后一格为「⋯」', (tester) async {
      await pump(tester, many, 380);
      expect(find.text('site1.com'), findsOneWidget, reason: '显示域名，去掉 www.');
      expect(find.text('site5.com'), findsOneWidget);
      expect(find.text('site6.com'), findsNothing);
      expect(find.text('⋯'), findsOneWidget);
      // 两行，且每个格子等宽。
      final a = tester.getRect(find.text('site1.com'));
      final d = tester.getRect(find.text('site4.com'));
      expect(d.top, greaterThan(a.bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏每行 2 个；数量放得下时不显示「⋯」', (tester) async {
      await pump(tester, many, 300);
      expect(find.text('site3.com'), findsOneWidget);
      expect(find.text('site4.com'), findsNothing);
      expect(find.text('⋯'), findsOneWidget);
      await pump(tester, many.take(4).toList(), 300);
      expect(find.text('site4.com'), findsOneWidget);
      expect(find.text('⋯'), findsNothing);
    });

    testWidgets('点「⋯」弹出全部来源', (tester) async {
      await pump(tester, many, 380);
      await tester.tap(find.text('⋯'));
      await tester.pumpAndSettle();
      expect(find.text('来源（8）'), findsOneWidget);
      expect(find.text('标题 1'), findsOneWidget);
      // 来源多时面板内可滚动。
      await tester.scrollUntilVisible(
        find.text('标题 8'),
        100,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('标题 8'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('预览文字去掉 Markdown 标记', () {
    expect(plainMarkdown('## 标题\n- **粗体** `代码`\n> 引用'), '标题\n· 粗体 代码\n引用');
  });

  testWidgets('双击采纳：快速点两下按钮 / 展开不算，点两下空白处才算', (tester) async {
    var count = 0;
    var buttonTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DoubleTapListener(
            onDoubleTap: () => count++,
            child: Column(
              children: [
                GestureDetector(
                  onTap: () => buttonTaps++,
                  child: const SizedBox(
                    width: 200,
                    height: 50,
                    child: Text('按钮'),
                  ),
                ),
                const SizedBox(width: 200, height: 200, child: Text('正文')),
              ],
            ),
          ),
        ),
      ),
    );
    Future<void> doubleTap(Finder f) async {
      await tester.tap(f);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(f);
      await tester.pump(const Duration(milliseconds: 400));
    }

    await doubleTap(find.text('按钮'));
    expect(buttonTaps, 2);
    expect(count, 0);
    await doubleTap(find.text('正文'));
    expect(count, 1);
  });

  testWidgets('发送失败：文字、引用、前文总结放回输入栏', (tester) async {
    final c = InputBarController();
    final chat = _FakeChat()..fail = true;
    final summary = StreamController<String>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatServiceProvider.overrideWithValue(chat),
          conversationProvider.overrideWith((ref, id) => null),
        ],
        child: MiuixSystemTheme(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: ChatInputBar(
                  conversationId: 'c',
                  controller: c,
                  generating: false,
                  webSearchSupported: false,
                  hasParticipants: true,
                  onError: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    c.setQuote('引用');
    c.setSummary(SummaryJob(summary.stream));
    summary.add('总结');
    await summary.close();
    await tester.pump();
    await tester.enterText(find.byType(EditableText), '问题');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(c.quote, '引用');
    expect(c.summary?.text, '总结');
    expect(find.text('问题'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  test('打开链接：无效链接返回 false 不抛异常', () async {
    expect(await openLink('not a url'), isFalse);
    expect(await openLink('https://'), isFalse);
  });
}
