import 'dart:io';

import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/image_store.dart';
import 'package:agent/data/sync/cloud_store.dart';
import 'package:agent/data/sync/sync_engine.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一台模拟设备：自己的数据库和图片目录，共用同一个「云端」文件夹。
class _Device {
  _Device(this.name, Directory cloud, Directory tmp)
    : db = AppDatabase(NativeDatabase.memory()),
      images = ImageStore(() async => Directory('${tmp.path}/$name')) {
    engine = SyncEngine(db, DirectoryCloudStore(cloud), images, deviceId: name);
  }

  final String name;
  final AppDatabase db;
  final ImageStore images;
  late final SyncEngine engine;

  Future<SyncReport> sync() => engine.sync();

  Future<void> addConversation(
    String id,
    String title, {
    String text = 'hi',
  }) async {
    final now = DateTime.now();
    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: id,
            title: title,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.addMessage(
      MessagesCompanion.insert(
        id: '$id-m1',
        conversationId: id,
        role: 'user',
        partsJson: Value(ContentPart.encodeList([TextPart(text)])),
        createdAt: now,
      ),
    );
  }

  Future<List<String>> titles() async => [
    for (final c in await (db.select(
      db.conversations,
    )..orderBy([(c) => OrderingTerm.asc(c.id)])).get())
      c.title,
  ];
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late Directory tmp;
  late Directory cloud;
  late _Device a;
  late _Device b;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync_test');
    cloud = Directory('${tmp.path}/cloud')..createSync();
    a = _Device('a', cloud, tmp);
    b = _Device('b', cloud, tmp);
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
    await tmp.delete(recursive: true);
  });

  test('触发器：修改 / 新消息刷新对话的版本号，删除留下删除记录', () async {
    await a.addConversation('c1', '一');
    Future<int> ver() async =>
        (await a.db
                .customSelect(
                  "SELECT modified_at FROM conversations WHERE id = 'c1'",
                )
                .getSingle())
            .read<int>('modified_at');
    final v1 = await ver();
    await _tick();
    await (a.db.update(a.db.conversations)..where((c) => c.id.equals('c1')))
        .write(const ConversationsCompanion(title: Value('二')));
    final v2 = await ver();
    expect(v2, greaterThan(v1));
    await _tick();
    await (a.db.update(a.db.messages)..where((m) => m.id.equals('c1-m1')))
        .write(const MessagesCompanion(status: Value('done')));
    expect(await ver(), greaterThan(v2));

    await a.db.deleteConversation('c1');
    final t = await a.db.select(a.db.tombstones).get();
    expect(t.map((x) => '${x.kind}/${x.id}'), contains('conversations/c1'));
  });

  test('两台设备互相同步对话和消息，再同步不会来回推送', () async {
    await a.addConversation('c1', 'A 的对话', text: '你好');
    await b.addConversation('c2', 'B 的对话');
    await a.sync();
    await b.sync();
    await a.sync();
    expect(await a.titles(), ['A 的对话', 'B 的对话']);
    expect(await b.titles(), ['A 的对话', 'B 的对话']);
    final msgs = await b.db.messagesOf('c1');
    expect(ContentPart.decodeList(msgs.single.partsJson).text, '你好');

    // 稳定后再同步：什么都不传。
    final ra = await a.sync();
    final rb = await b.sync();
    expect(ra.pulled + ra.pushed + rb.pulled + rb.pushed, 0);
  });

  test('后修改的为准；删除也会同步', () async {
    await a.addConversation('c1', '原标题');
    await a.sync();
    await b.sync();

    await (b.db.update(b.db.conversations)..where((c) => c.id.equals('c1')))
        .write(const ConversationsCompanion(title: Value('B 改的')));
    await _tick();
    await (a.db.update(a.db.conversations)..where((c) => c.id.equals('c1')))
        .write(const ConversationsCompanion(title: Value('A 后改的')));
    await b.sync();
    await a.sync();
    await b.sync();
    expect(await a.titles(), ['A 后改的']);
    expect(await b.titles(), ['A 后改的']);

    await b.db.deleteConversation('c1');
    await b.sync();
    final r = await a.sync();
    expect(r.deleted, 1);
    expect(await a.titles(), isEmpty);
    expect(await a.db.messagesOf('c1'), isEmpty);
  });

  test('图片随对话同步；旧版本文件被清理', () async {
    final part = await a.images.save(
      Uint8List.fromList([1, 2, 3]),
      'image/png',
    );
    await a.addConversation('c1', '有图');
    await a.db.addMessage(
      MessagesCompanion.insert(
        id: 'img',
        conversationId: 'c1',
        role: 'user',
        partsJson: Value(ContentPart.encodeList([part])),
        createdAt: DateTime.now(),
      ),
    );
    await a.sync();
    await b.sync();
    expect(await b.images.readBytes(part.path), [1, 2, 3]);

    for (var i = 0; i < 3; i++) {
      await _tick();
      await (a.db.update(a.db.conversations)..where((c) => c.id.equals('c1')))
          .write(ConversationsCompanion(title: Value('改 $i')));
      await a.sync();
    }
    await b.sync();
    await a.sync();
    final files = Directory('${cloud.path}/records/conversations')
        .listSync()
        .map((f) => f.path.split('/').last)
        .toList();
    expect(files, hasLength(1));
    expect(await b.titles(), ['改 2']);
  });

  test('渠道和路由同步：依赖顺序正确，删除渠道连带删除路由', () async {
    await a.db
        .into(a.db.channels)
        .insert(
          ChannelsCompanion.insert(
            id: 'ch',
            name: '中转',
            protocol: 'openai_chat',
            baseUrl: 'https://x',
            createdAt: DateTime.now(),
          ),
        );
    await a.db
        .into(a.db.models)
        .insert(ModelsCompanion.insert(id: 'm', displayName: 'M'));
    await a.db
        .into(a.db.modelRoutes)
        .insert(
          ModelRoutesCompanion.insert(
            id: 'r',
            modelId: 'm',
            channelId: 'ch',
            upstreamModel: 'gpt',
          ),
        );
    await a.sync();
    await b.sync();
    expect(await b.db.select(b.db.modelRoutes).get(), hasLength(1));

    await (a.db.delete(a.db.channels)..where((c) => c.id.equals('ch'))).go();
    await a.sync();
    await b.sync();
    expect(await b.db.select(b.db.channels).get(), isEmpty);
    expect(await b.db.select(b.db.modelRoutes).get(), isEmpty);
    expect(await b.db.select(b.db.models).get(), hasLength(1));
  });
}
