// 用本地模拟服务做端到端验证（真实 HTTP + 真实 SQLite）。
// 需要先启动：python3 tool/mock_server.py 8787 和 python3 tool/mock_server.py 8788 fail
// 运行：flutter test --tags live --run-skipped
// 未启动时自动跳过。
@Tags(['live'])
library;

import 'dart:io';

import 'package:agent/core/api/chat_client.dart';
import 'package:agent/core/api/channel_client.dart';
import 'package:agent/core/api/protocol.dart';
import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/core/chat/participant.dart';
import 'package:agent/core/routing/model_router.dart';
import 'package:agent/data/chat_service.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/image_store.dart';
import 'package:agent/data/repositories/channel_repository.dart';
import 'package:agent/data/secure/key_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Future<bool> _up(int port) async {
  try {
    final s = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 300),
    );
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  late bool available;
  setUpAll(() async => available = await _up(8787) && await _up(8788));

  test('主备：坏渠道 500 后自动切到好渠道，并记录实际渠道', () async {
    if (!available) return markTestSkipped('mock servers not running');
    final db = AppDatabase(NativeDatabase.memory());
    final keys = MemoryKeyStore();
    final repo = ChannelRepository(db, keys);
    final tmp = await Directory.systemTemp.createTemp('live');
    final chat = ChatService(
      db: db,
      channels: repo,
      client: ChatClient(),
      router: ModelRouter(),
      images: ImageStore(() async => tmp),
    );

    // 两个渠道都从云端拉模型，再同步同一个模型。
    Future<String> add(String name, int port) async {
      final id = await repo.saveChannel(
        name: name,
        presetId: 'custom',
        protocol: ApiProtocol.openaiChat,
        baseUrl: 'http://127.0.0.1:$port',
        apiKey: 'sk-test-local',
      );
      final remote = await ChannelClient().listModels(
        await repo.endpointFor((await repo.getChannel(id))!),
      );
      expect(remote.map((m) => m.id), contains('mock-chat'));
      await repo.syncChannelModels(id, ['mock-chat']);
      return id;
    }

    final bad = await add('坏渠道', 8788);
    final good = await add('好渠道', 8787);

    final model = (await repo.watchModels().first).single;
    expect(model.routes, hasLength(2), reason: '同名模型合并为一个逻辑模型');
    await repo.setRouteStrategy(model.model.id, RouteStrategy.failover.id);
    for (final r in model.routes) {
      await repo.updateRoute(r.route.id, priority: r.channel.id == bad ? 0 : 1);
    }

    final conv = await chat.createConversation([
      Participant(modelId: model.model.id),
    ]);
    await chat.send(conv, '测试故障切换');

    Message? last;
    for (var i = 0; i < 300; i++) {
      last = (await db.watchMessages(conv).first).last;
      if (!MsgStatus.isActive(last.status)) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(last!.status, MsgStatus.done, reason: last.error);
    expect(last.channelId, good);
    expect(ContentPart.decodeList(last.partsJson).text, contains('@ :8787'));

    await db.close();
    await tmp.delete(recursive: true);
  });

  test('Anthropic 协议端到端流式', () async {
    if (!available) return markTestSkipped('mock servers not running');
    final endpointRepo = ChannelRepository(
      AppDatabase(NativeDatabase.memory()),
      MemoryKeyStore(),
    );
    final id = await endpointRepo.saveChannel(
      name: 'a',
      presetId: 'custom',
      protocol: ApiProtocol.anthropic,
      baseUrl: 'http://127.0.0.1:8787',
      apiKey: 'sk-test-local',
    );
    final ep = await endpointRepo.endpointFor(
      (await endpointRepo.getChannel(id))!,
    );
    final events = await ChatClient()
        .stream(
          ep,
          const ChatRequest(
            model: 'claude-sonnet-4-5',
            turns: [ChatTurn(role: 'user', text: 'hi')],
          ),
        )
        .toList();
    final text = events.whereType<TextDelta>().map((e) => e.text).join();
    expect(text, contains('claude-sonnet-4-5'));
    expect(
      events.whereType<UsageEvent>().map((u) => u.output).whereType<int>(),
      [40],
    );
  });
}
