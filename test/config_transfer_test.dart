import 'dart:convert';
import 'dart:io';

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
      params: const GenParams(reasoning: ReasoningEffort.high),
    );

    final withKey = await ConfigTransfer(srcDb, srcKeys).export('pass1234');
    // 加密后的一串文本：看不到明文，每次导出（盐和随机数不同）结果都不一样。
    expect(withKey, startsWith(ConfigTransfer.encryptedPrefix));
    expect(withKey, isNot(contains('sk-secret')));
    expect(withKey, isNot(contains('\n')));
    expect(ConfigTransfer.isEncrypted(withKey), isTrue);
    expect(
      await ConfigTransfer(srcDb, srcKeys).export('pass1234'),
      isNot(withKey),
    );
    expect(
      (await ConfigTransfer.decrypt(
        withKey,
        'pass1234',
      ))['channels'][0]['apiKey'],
      'sk-secret',
    );

    final dstDb = AppDatabase(NativeDatabase.memory());
    final dstKeys = MemoryKeyStore();
    // 密码不对：解不开，什么也不写入。
    await expectLater(
      ConfigTransfer(dstDb, dstKeys).import(withKey, password: 'wrong'),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'm', contains('密码不对')),
      ),
    );
    expect(dstKeys.values, isEmpty);
    final msg = await ConfigTransfer(
      dstDb,
      dstKeys,
    ).import(withKey, password: 'pass1234');
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
    expect(
      GenParams.fromJson(agents.single.paramsJson).reasoning,
      ReasoningEffort.high,
    );

    // 重复导入不会重复插入；粘贴时被插进换行也能导入。
    final wrapped = withKey.replaceAllMapped(
      RegExp(r'.{40}'),
      (m) => '${m[0]}\n',
    );
    await ConfigTransfer(dstDb, dstKeys).import(wrapped, password: 'pass1234');
    expect(await dst.watchModels().first, hasLength(2));

    // 旧版导出：明文 JSON 和只做了 base64 编码的格式仍然可以导入。
    final json = await ConfigTransfer(srcDb, srcKeys).exportJson();
    expect(
      await ConfigTransfer(dstDb, dstKeys).import(json),
      contains('1 个渠道'),
    );
    final v1 =
        ConfigTransfer.prefix +
        base64Url.encode(gzip.encode(utf8.encode(json)));
    expect(await ConfigTransfer(dstDb, dstKeys).import(v1), contains('1 个渠道'));

    expect(
      () => ConfigTransfer(dstDb, dstKeys).import('{"x":1}'),
      throwsFormatException,
    );
    expect(
      () => ConfigTransfer(dstDb, dstKeys).import('not json'),
      throwsFormatException,
    );
    expect(
      () =>
          ConfigTransfer(dstDb, dstKeys).import('${ConfigTransfer.prefix}abc'),
      throwsFormatException,
    );

    await srcDb.close();
    await dstDb.close();
  });
}
