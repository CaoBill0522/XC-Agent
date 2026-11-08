import 'dart:io';

import 'package:agent/data/db/app_database.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> addConversation(String id, DateTime t) => db
      .into(db.conversations)
      .insert(
        ConversationsCompanion.insert(
          id: id,
          title: id,
          createdAt: t,
          updatedAt: t,
        ),
      );

  test('新消息会把会话顶到列表最前', () async {
    final t0 = DateTime(2026, 1, 1);
    await addConversation('a', t0);
    await addConversation('b', t0.add(const Duration(minutes: 1)));
    expect((await db.watchConversations().first).map((c) => c.id), ['b', 'a']);

    await db.addMessage(
      MessagesCompanion.insert(
        id: 'm1',
        conversationId: 'a',
        role: 'user',
        partsJson: const Value('[{"type":"text","text":"hi"}]'),
        createdAt: DateTime.now(),
      ),
    );
    expect((await db.watchConversations().first).map((c) => c.id), ['a', 'b']);
    expect((await db.watchMessages('a').first).single.id, 'm1');
  });

  test('删除会话级联删除消息', () async {
    await addConversation('a', DateTime(2026));
    await db.addMessage(
      MessagesCompanion.insert(
        id: 'm1',
        conversationId: 'a',
        role: 'user',
        createdAt: DateTime.now(),
      ),
    );
    await db.deleteConversation('a');
    expect(await db.select(db.messages).get(), isEmpty);
  });

  test('删除渠道级联删除其路由', () async {
    await db
        .into(db.channels)
        .insert(
          ChannelsCompanion.insert(
            id: 'c1',
            name: 'DeepSeek',
            protocol: 'openai_chat',
            baseUrl: 'https://api.deepseek.com',
            createdAt: DateTime.now(),
          ),
        );
    await db
        .into(db.models)
        .insert(ModelsCompanion.insert(id: 'm', displayName: 'deepseek-chat'));
    await db
        .into(db.modelRoutes)
        .insert(
          ModelRoutesCompanion.insert(
            id: 'r1',
            modelId: 'm',
            channelId: 'c1',
            upstreamModel: 'deepseek-chat',
          ),
        );
    await (db.delete(db.channels)..where((c) => c.id.equals('c1'))).go();
    expect(await db.select(db.modelRoutes).get(), isEmpty);
  });

  test('启动时清理没发过消息的空会话和「追问」对话，保留有消息 / 置顶的', () async {
    final dir = await Directory.systemTemp.createTemp('agent_db');
    final file = File('${dir.path}/a.sqlite');
    final t = DateTime(2026, 1, 1);
    var d = AppDatabase(NativeDatabase(file));
    Future<void> conv(String id, String title, {bool pinned = false}) => d
        .into(d.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: id,
            title: title,
            pinned: Value(pinned),
            createdAt: t,
            updatedAt: t,
          ),
        );
    await conv('empty', '新对话');
    await conv('follow', '追问：质能方程');
    await conv('followSent', '追问：相对论');
    await conv('pinned', '追问：置顶', pinned: true);
    await conv('normal', '普通对话');
    await d.addMessage(
      MessagesCompanion.insert(
        id: 'm',
        conversationId: 'followSent',
        role: 'user',
        createdAt: t,
      ),
    );
    await d.close();

    d = AppDatabase(NativeDatabase(file));
    final ids = (await d.watchConversations().first).map((c) => c.id).toSet();
    expect(ids, {'followSent', 'pinned', 'normal'});
    await d.close();
    await dir.delete(recursive: true);
  });
}
