import 'dart:convert';

import 'package:agent/core/api/protocol.dart';
import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/data/config_transfer.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/repositories/agent_repository.dart';
import 'package:agent/data/repositories/channel_repository.dart';
import 'package:agent/data/secure/key_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('导出 → 导入到另一台设备：渠道、模型、路由、助手、Key 都恢复', () async {
    final srcDb = AppDatabase(NativeDatabase.memory());
    final srcKeys = MemoryKeyStore();
    final src = ChannelRepository(srcDb, srcKeys);
    final ch = await src.saveChannel(
      name: '中转',
      presetId: 'custom',
      protocol: ApiProtocol.anthropic,
      baseUrl: 'https://relay.example.com',
      apiKey: 'sk-secret',
    );
    await src.syncChannelModels(ch, ['claude-sonnet-4-5', 'gpt-4o']);
    final modelId = (await src.watchModels().first).first.model.id;
    await AgentRepository(srcDb).save(
      name: '翻译官',
      modelId: modelId,
      systemPrompt: '翻译',
      params: const GenParams(temperature: 0.3),
    );

    final noKey = await ConfigTransfer(
      srcDb,
      srcKeys,
    ).export(includeKeys: false);
    expect(noKey, isNot(contains('sk-secret')));
    final withKey = await ConfigTransfer(
      srcDb,
      srcKeys,
    ).export(includeKeys: true);
    expect((jsonDecode(withKey) as Map)['channels'][0]['apiKey'], 'sk-secret');

    final dstDb = AppDatabase(NativeDatabase.memory());
    final dstKeys = MemoryKeyStore();
    final msg = await ConfigTransfer(dstDb, dstKeys).import(withKey);
    expect(msg, contains('1 个渠道（含 1 个 Key）'));

    final dst = ChannelRepository(dstDb, dstKeys);
    final models = await dst.watchModels().first;
    expect(
      models.map((m) => m.model.displayName),
      unorderedEquals(['claude-sonnet-4-5', 'gpt-4o']),
    );
    expect(models.every((m) => m.routes.single.channel.name == '中转'), isTrue);
    expect(dstKeys.values[ch], 'sk-secret');
    final agents = await AgentRepository(dstDb).watchAll().first;
    expect(agents.single.name, '翻译官');
    expect(GenParams.fromJson(agents.single.paramsJson).temperature, 0.3);

    // 重复导入不会重复插入。
    await ConfigTransfer(dstDb, dstKeys).import(withKey);
    expect(await dst.watchModels().first, hasLength(2));

    expect(
      () => ConfigTransfer(dstDb, dstKeys).import('{"x":1}'),
      throwsFormatException,
    );
    expect(
      () => ConfigTransfer(dstDb, dstKeys).import('not json'),
      throwsFormatException,
    );

    await srcDb.close();
    await dstDb.close();
  });
}
