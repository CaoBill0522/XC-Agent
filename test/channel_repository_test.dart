import 'package:agent/core/api/protocol.dart';
import 'package:agent/core/models/capabilities.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/repositories/channel_repository.dart';
import 'package:agent/data/secure/key_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late MemoryKeyStore keys;
  late ChannelRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    keys = MemoryKeyStore();
    repo = ChannelRepository(db, keys);
  });
  tearDown(() => db.close());

  Future<String> addChannel(
    String name, {
    ApiProtocol protocol = ApiProtocol.openaiChat,
  }) => repo.saveChannel(
    name: name,
    presetId: 'custom',
    protocol: protocol,
    baseUrl: 'https://$name.example.com',
    apiKey: ' key-$name ',
  );

  test('保存渠道：Key 进安全存储（去空格），地址规范化，不进数据库', () async {
    final id = await addChannel('relay');
    final c = (await repo.getChannel(id))!;
    expect(c.baseUrl, 'https://relay.example.com/v1');
    expect(keys.values[id], 'key-relay');
    expect((await repo.endpointFor(c)).apiKey, 'key-relay');
  });

  test('不同渠道的同名模型合并成一个逻辑模型（忽略大小写和 vendor/ 前缀）', () async {
    final a = await addChannel('a');
    final b = await addChannel('b');
    await repo.syncChannelModels(a, ['gpt-4o', 'deepseek-chat']);
    await repo.syncChannelModels(b, ['openai/GPT-4o']);

    final models = await repo.watchModels().first;
    expect(
      models.map((m) => m.model.displayName),
      unorderedEquals(['gpt-4o', 'deepseek-chat']),
    );

    final gpt = models.firstWhere((m) => m.model.displayName == 'gpt-4o');
    expect(
      gpt.routes.map((r) => r.route.upstreamModel),
      unorderedEquals(['gpt-4o', 'openai/GPT-4o']),
    );
    expect(gpt.routes.map((r) => r.channel.name), unorderedEquals(['a', 'b']));
    expect(gpt.capabilities, contains(ModelCapability.vision));
  });

  test('取消选择会删除路由，无路由的模型被清理，用户改过的能力保留', () async {
    final a = await addChannel('a');
    final b = await addChannel('b');
    await repo.syncChannelModels(a, ['gpt-4o', 'deepseek-chat']);
    await repo.syncChannelModels(b, ['gpt-4o']);

    final gpt = (await repo.watchModels().first).firstWhere(
      (m) => m.model.displayName == 'gpt-4o',
    );
    await repo.updateModel(
      gpt.model.id,
      capabilities: {ModelCapability.reasoning},
    );

    await repo.syncChannelModels(a, ['gpt-4o']);
    var models = await repo.watchModels().first;
    expect(models.map((m) => m.model.displayName), ['gpt-4o']);
    expect(models.single.capabilities, {ModelCapability.reasoning});
    expect(await repo.channelModelNames(a), {'gpt-4o'});

    // 删除渠道 a：gpt-4o 仍挂在 b 上，保留。
    await repo.deleteChannel(a);
    models = await repo.watchModels().first;
    expect(models.single.routes.single.channel.name, 'b');
    expect(keys.values.containsKey(a), isFalse);

    // 再删 b：模型没有路由了，一并清理。
    await repo.deleteChannel(b);
    expect(await repo.watchModels().first, isEmpty);
  });

  test('渠道列表带模型数量', () async {
    final a = await addChannel('a');
    await addChannel('b');
    await repo.syncChannelModels(a, ['m1', 'm2', 'm3']);
    final list = await repo.watchChannels().first;
    expect(
      {for (final s in list) s.channel.name: s.modelCount},
      {'a': 3, 'b': 0},
    );
  });
}
