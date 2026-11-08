// 冒烟测试：用真实（内存）数据库打开每个页面并执行主要交互，任何异常 / 断言 / 溢出都会失败。
// debug 断言类的问题（如动画曲线越界导致界面卡死）只在这种覆盖下才能提前发现。
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';

import 'package:agent/core/api/protocol.dart';
import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/core/chat/conversation_mode.dart';
import 'package:agent/core/chat/participant.dart';
import 'package:agent/data/chat_service.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/image_store.dart';
import 'package:agent/data/providers.dart';
import 'package:agent/data/repositories/agent_repository.dart';
import 'package:agent/data/repositories/channel_repository.dart';
import 'package:agent/data/secure/key_store.dart';
import 'package:agent/features/agents/agents_page.dart';
import 'package:agent/features/channels/channel_edit_page.dart';
import 'package:agent/features/channels/channels_page.dart';
import 'package:agent/features/chat/chat_page.dart';
import 'package:agent/features/chat/follow_up.dart';
import 'package:agent/features/chat/participant_picker.dart';
import 'package:agent/features/home/home_shell.dart';
import 'package:agent/features/models/models_page.dart';
import 'package:agent/features/settings/appearance_page.dart';
import 'package:agent/features/settings/data_page.dart';
import 'package:agent/features/settings/settings_page.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

late AppDatabase db;
late MemoryKeyStore keys;
late Directory tmp;
late String chatConv;
late String chainConv;
late String multiConv;
late String channelId;
late String modelId;
late String agentId;
late PendingDrafts drafts;

Future<void> _seed() async {
  final repo = ChannelRepository(db, keys);
  channelId = await repo.saveChannel(
    name: '测试渠道',
    presetId: 'custom',
    protocol: ApiProtocol.openaiChat,
    baseUrl: 'https://relay.example.com',
    apiKey: 'k',
  );
  final other = await repo.saveChannel(
    name: '备用渠道',
    presetId: 'custom',
    protocol: ApiProtocol.anthropic,
    baseUrl: 'https://b.example.com',
    apiKey: 'k',
  );
  await repo.syncChannelModels(channelId, [
    'gpt-4o',
    'deepseek-reasoner',
    'dall-e-3',
  ]);
  await repo.syncChannelModels(other, ['gpt-4o']);
  final models = await repo.watchModels().first;
  modelId = models.firstWhere((m) => m.model.displayName == 'gpt-4o').model.id;
  final reasoner = models
      .firstWhere((m) => m.model.displayName == 'deepseek-reasoner')
      .model
      .id;
  agentId = await AgentRepository(db).save(
    name: '翻译官',
    modelId: modelId,
    systemPrompt: '你是翻译',
    params: const GenParams(temperature: 0.3),
  );

  // 不经过网络：直接写入各种形态的消息。
  final now = DateTime(2026, 1, 1);
  Future<String> conv(
    List<Participant> ps,
    ConversationMode mode,
    String title,
  ) async {
    final id = 'c-$title';
    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: id,
            title: title,
            mode: Value(mode.id),
            participantsJson: Value(Participant.encodeList(ps)),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> msg(
    String conv,
    String id,
    String role,
    List<ContentPart> parts, {
    String? group,
    int? step,
    bool adopted = true,
    String status = MsgStatus.done,
    String? model,
    int t = 0,
  }) {
    return db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: id,
            conversationId: conv,
            role: role,
            partsJson: Value(ContentPart.encodeList(parts)),
            groupId: Value(group),
            stepIndex: Value(step),
            adopted: Value(adopted),
            modelId: Value(model),
            status: Value(status),
            usageJson: const Value('{"output":42}'),
            error: Value(status == MsgStatus.error ? '「测试渠道」请求失败\nboom' : null),
            createdAt: now.add(Duration(seconds: t)),
          ),
        );
  }

  const md =
      '## 标题\n\n- 列表 **粗体** `code`\n\n\$\$E=mc^2\$\$\n\n```dart\nprint(1);\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |';
  chatConv = await conv(
    [Participant(modelId: modelId)],
    ConversationMode.single,
    'single',
  );
  await msg(chatConv, 'u1', 'user', [const TextPart('你好')], t: 1);
  await msg(
    chatConv,
    'a1',
    'assistant',
    [
      const ThinkingPart('想想'),
      const TextPart(md),
      const CitationPart('https://a.com', 'A'),
    ],
    group: 'g1',
    model: modelId,
    t: 2,
  );
  await msg(chatConv, 'u2', 'user', [
    const ImagePart('missing.png', 'image/png'),
    const TextPart('看图'),
  ], t: 3);
  await msg(
    chatConv,
    'a2',
    'assistant',
    [],
    group: 'g2',
    model: modelId,
    status: MsgStatus.error,
    t: 4,
  );
  await msg(
    chatConv,
    'a3',
    'assistant',
    [const TextPart('生成中')],
    group: 'g3',
    model: modelId,
    status: MsgStatus.streaming,
    t: 5,
  );

  multiConv = await conv(
    [Participant(modelId: modelId), Participant(modelId: reasoner)],
    ConversationMode.multi,
    'multi',
  );
  await msg(multiConv, 'mu', 'user', [const TextPart('比较')], t: 1);
  await msg(
    multiConv,
    'm1',
    'assistant',
    [const TextPart(md)],
    group: 'mg',
    model: modelId,
    t: 2,
  );
  await msg(
    multiConv,
    'm2',
    'assistant',
    [const TextPart('另一个')],
    group: 'mg',
    model: reasoner,
    adopted: false,
    t: 3,
  );

  chainConv = await conv(
    [
      Participant(modelId: modelId),
      Participant(modelId: reasoner, agentId: agentId),
      Participant(modelId: modelId),
    ],
    ConversationMode.chain,
    'chain',
  );
  await msg(chainConv, 'cu', 'user', [const TextPart('接力')], t: 1);
  await msg(
    chainConv,
    's0',
    'assistant',
    [const TextPart(md)],
    group: 'cg',
    step: 0,
    adopted: false,
    model: modelId,
    t: 2,
  );
  await msg(
    chainConv,
    's1',
    'assistant',
    [const TextPart('第二步')],
    group: 'cg',
    step: 1,
    adopted: false,
    model: reasoner,
    status: MsgStatus.streaming,
    t: 3,
  );
  await msg(
    chainConv,
    's2',
    'assistant',
    [],
    group: 'cg',
    step: 2,
    adopted: false,
    model: modelId,
    status: MsgStatus.pending,
    t: 4,
  );
}

Future<String> _newEmpty() async {
  final now = DateTime.now();
  await db
      .into(db.conversations)
      .insert(
        ConversationsCompanion.insert(
          id: 'empty',
          title: ChatService.defaultTitle,
          createdAt: now,
          updatedAt: now,
        ),
      );
  return 'empty';
}

Future<Conversation?> _conv(String id) => (db.select(
  db.conversations,
)..where((c) => c.id.equals(id))).getSingleOrNull();

Future<Widget> _app(
  Widget home, {
  Brightness brightness = Brightness.light,
}) async {
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      keyStoreProvider.overrideWithValue(keys),
      imageStoreProvider.overrideWithValue(ImageStore(() async => tmp)),
      pendingDraftsProvider.overrideWithValue(drafts),
    ],
    child: MiuixTheme(
      data: MiuixThemeData.of(brightness),
      child: MaterialApp(home: home),
    ),
  );
}

/// 让数据库流、动画都跑完；期间出现的任何异常都会让测试失败。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(tester.takeException(), isNull);
}

Future<void> _open(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(402, 874),
  Brightness b = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    await tester.runAsync(() => _app(page, brightness: b)) as Widget,
  );
  await _settle(tester);
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final f = find.text(text);
  expect(f, findsWidgets, reason: '找不到「$text」');
  await tester.tap(f.first, warnIfMissed: false);
  await _settle(tester);
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    keys = MemoryKeyStore();
    drafts = PendingDrafts();
    tmp = await Directory.systemTemp.createTemp('smoke');
    await _seed();
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  for (final b in Brightness.values) {
    testWidgets('首页（窄屏 + 宽屏）· $b', (tester) async {
      await _open(tester, const HomeShell(), b: b);
      expect(find.text('chain'), findsOneWidget);
      await _open(tester, const HomeShell(), size: const Size(1200, 800), b: b);
      await _tapText(tester, 'multi');
      await _tapText(tester, '设置');
      await _close(tester);
    });

    testWidgets('聊天页：单聊各种消息状态、多 Agent、接力 · $b', (tester) async {
      for (final id in [chatConv, multiConv, chainConv]) {
        await _open(tester, ChatPage(conversationId: id), b: b);
        await _open(
          tester,
          ChatPage(conversationId: id),
          size: const Size(1200, 900),
          b: b,
        );
      }
      // 接力：展开第一步、切换多 Agent 标签。
      await _open(tester, ChatPage(conversationId: chainConv), b: b);
      await _tapText(tester, '完成');
      await _open(tester, ChatPage(conversationId: multiConv), b: b);
      await _tapText(tester, 'deepseek-reasoner');
      await _tapText(tester, '采纳');
      await _close(tester);
    });
  }

  testWidgets('新会话：在聊天页选择对话方式；什么都没做就离开时被删除', (tester) async {
    final id = (await tester.runAsync(_newEmpty))!;
    await _open(tester, ChatPage(conversationId: id));
    expect(find.text('这次想怎么对话？'), findsOneWidget);
    expect(find.text('沿用上次'), findsNothing, reason: '没有上次的设置');
    await _tapText(tester, '接力分析');
    expect(find.text('选择模型'), findsWidgets, reason: '进入了选择页');
    expect(find.text(ConversationMode.chain.description), findsOneWidget);
    await _close(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(await tester.runAsync(() => _conv(id)), isNull);
  });

  testWidgets('新会话：「沿用上次」一键套用上次的模式和模型', (tester) async {
    final id = (await tester.runAsync(_newEmpty))!;
    SharedPreferences.setMockInitialValues({
      'last_participants': Participant.encodeList([
        Participant(modelId: modelId),
        Participant(modelId: modelId, agentId: agentId),
      ]),
      'last_mode': ConversationMode.chain.id,
    });
    await _open(
      tester,
      ChatPage(conversationId: id),
      size: const Size(1200, 900),
    );
    expect(find.text('接力分析：gpt-4o → 翻译官'), findsOneWidget);
    await _tapText(tester, '沿用上次');
    await _settle(tester);
    final conv = await tester.runAsync(() => _conv(id));
    expect(conv!.mode, 'chain');
    expect(find.text('有什么可以帮你？'), findsOneWidget);
    await _close(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(
      await tester.runAsync(() => _conv(id)),
      isNotNull,
      reason: '已设置的会话不删除',
    );
  });

  // 长对话（倒序列表、可滚动）里展开接力步骤：该步顶部全程不动，只往下展开。
  testWidgets('接力：展开 / 收起某一步时顶部不动', (tester) async {
    final long = List.filled(8, '这是一段很长的分析内容，用来撑高卡片。' * 6).join('\n\n');
    await tester.runAsync(() async {
      await (db.update(
        db.messages,
      )..where((m) => m.id.isIn(['s0', 's1', 's2']))).write(
        MessagesCompanion(
          partsJson: Value(ContentPart.encodeList([TextPart(long)])),
          status: const Value(MsgStatus.done),
        ),
      );
      await (db.update(db.messages)..where((m) => m.id.equals('s2'))).write(
        const MessagesCompanion(adopted: Value(true)),
      );
    });
    await _open(tester, ChatPage(conversationId: chainConv));
    // 第 2 步（折叠）的标题。
    final step2 = find.text('完成').at(1);
    await tester.ensureVisible(step2);
    await _settle(tester);
    final before = tester.getTopLeft(step2).dy;
    final sc = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final pixelsBefore = sc.position.pixels;
    await tester.tap(step2, warnIfMissed: false);
    for (var i = 0; i < 45; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getTopLeft(step2).dy,
        moreOrLessEquals(before, epsilon: 0.5),
        reason: '第 $i 帧顶部移动了',
      );
    }
    // 确实展开了（列表为保持顶部不动而滚动了），且之后恢复正常。
    expect(sc.position.pixels, greaterThan(pixelsBefore + 50));
    expect(find.textContaining('这是一段很长的分析内容'), findsWidgets);
    await _settle(tester);

    // 回归：列表滚到最顶端时收起，曾被重复修正，页面整体往上跑一下。
    expect(
      sc.position.pixels,
      moreOrLessEquals(sc.position.maxScrollExtent, epsilon: 1),
    );
    await tester.tap(step2, warnIfMissed: false);
    for (var i = 0; i < 45; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getTopLeft(step2).dy,
        moreOrLessEquals(before, epsilon: 0.5),
        reason: '收起第 $i 帧顶部移动了',
      );
    }
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  // iOS：文字选择区会让位给外层横滑（Android 上横向拖动文字是选择文字，需在空白处滑）。
  testWidgets(
    '多 Agent：卡片左右滑动切换回答，双击采纳',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      await _open(tester, ChatPage(conversationId: multiConv));
      expect(find.text('另一个'), findsNothing);
      // 向左滑：切到下一个回答。
      await tester.fling(find.text('标题').first, const Offset(-250, 0), 1200);
      await _settle(tester);
      expect(find.text('另一个'), findsOneWidget);
      // 已在最后一个，再左滑不变。
      await tester.fling(find.text('另一个'), const Offset(-250, 0), 1200);
      await _settle(tester);
      expect(find.text('另一个'), findsOneWidget);
      // 双击采纳当前（第二个）回答。
      await tester.tap(find.text('另一个'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('另一个'));
      await _settle(tester);
      final m2 = await tester.runAsync(
        () => (db.select(
          db.messages,
        )..where((m) => m.id.equals('m2'))).getSingle(),
      );
      expect(m2!.adopted, isTrue);
      // 向右滑回第一个。
      await tester.fling(find.text('另一个'), const Offset(250, 0), 1200);
      await _settle(tester);
      expect(find.text('另一个'), findsNothing);
      await _close(tester);
    },
  );

  testWidgets('新对话追问：输入框上方显示流式生成的前文总结和引用', (tester) async {
    final summary = StreamController<String>();
    drafts.put(
      chatConv,
      PendingDraft(quote: '质能方程', summary: SummaryJob(summary.stream)),
    );
    await _open(tester, ChatPage(conversationId: chatConv));
    expect(find.text('正在总结前文…'), findsOneWidget);
    expect(find.text('质能方程'), findsOneWidget);
    expect(find.text('继续追问…'), findsOneWidget);
    summary.add('用户问了相对论');
    await _settle(tester);
    expect(find.text('用户问了相对论'), findsOneWidget);
    await summary.close();
    await _settle(tester);
    expect(find.text('前文总结（发送时作为背景一起发出）'), findsOneWidget);
    // 移除引用。
    await tester.tap(
      find.byType(QuoteCard).evaluate().isEmpty
          ? find.text('质能方程')
          : find.descendant(
              of: find.byType(QuoteCard),
              matching: find.byType(MiuixIcon),
            ),
    );
    await _settle(tester);
    expect(find.byType(QuoteCard), findsNothing);
    await _close(tester);
  });

  testWidgets('当前对话追问：选中内容出现在输入框上方', (tester) async {
    await _open(tester, ChatPage(conversationId: chatConv));
    final actions = tester.widget<ChatActions>(find.byType(ChatActions));
    actions.quoteHere('一段看不懂的话');
    await _settle(tester);
    expect(
      find.descendant(
        of: find.byType(QuoteCard),
        matching: find.text('一段看不懂的话'),
      ),
      findsOneWidget,
    );
    expect(find.text('继续追问…'), findsOneWidget);
    await _close(tester);
  });

  testWidgets(
    '首页新建按钮：右边距与底边距相等',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
      addTearDown(tester.view.resetPadding);
      await _open(tester, const HomeShell());
      final fab = tester.getRect(find.byType(MiuixFloatingActionButton));
      const screen = Size(402, 874);
      expect(screen.width - fab.right, 24);
      expect(screen.height - fab.bottom, 24);
      await _close(tester);
    },
  );

  test('非 iOS 平台：底部有导航栏时按钮避开，右边距同步加大', () {
    const safe = EdgeInsets.only(bottom: 48);
    expect(CornerFab.gapFor(TargetPlatform.android, safe), 60);
    expect(CornerFab.gapFor(TargetPlatform.android, EdgeInsets.zero), 24);
    expect(CornerFab.gapFor(TargetPlatform.iOS, safe), 24);
  });

  testWidgets('模型选择：三种模式切换、接力排序', (tester) async {
    await _open(tester, ParticipantPickerPage(conversationId: chainConv));
    expect(find.text('执行顺序（第 1 步收到原始问题，之后每步收到原始问题 + 上一步结果）'), findsOneWidget);
    await tester.tap(find.byType(RotatedBox).first, warnIfMissed: false);
    await _settle(tester);
    await _open(tester, ParticipantPickerPage(conversationId: chatConv));
    await _tapText(tester, 'deepseek-reasoner');
    await _close(tester);
  });

  testWidgets('设置各页面', (tester) async {
    for (final page in <Widget>[
      const SettingsPage(),
      const ChannelsPage(),
      const PresetPickerPage(),
      const ModelsPage(),
      const AgentsPage(),
      const AppearancePage(),
      const DataPage(),
      ChannelEditPage(channelId: channelId),
      ModelDetailPage(modelId: modelId),
      AgentEditPage(agentId: agentId),
      const AgentEditPage(),
    ]) {
      await _open(tester, page);
      await _open(tester, page, b: Brightness.dark);
    }
    // 外观：打开动态取色，主题色区域展开。
    await _open(tester, const AppearancePage());
    await tester.tap(find.byType(MiuixSwitch).first);
    await _settle(tester);
    expect(find.text('主题色'), findsOneWidget);
    // 模型详情：路由策略相关项。
    await _open(tester, ModelDetailPage(modelId: modelId));
    expect(find.text('路由策略'), findsOneWidget);
    await _close(tester);
  });
}
