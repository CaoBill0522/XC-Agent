import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [Channels, Models, ModelRoutes, Agents, Conversations, Messages],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'agent'));

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.addColumn(models, models.matchKey);
      if (from < 3) {
        await m.addColumn(conversations, conversations.participantsJson);
        await m.addColumn(conversations, conversations.webSearch);
      }
      if (from < 4) await m.addColumn(messages, messages.stepIndex);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // 上次退出时仍在生成的消息标记为已停止。
      await customStatement(
        "UPDATE messages SET status = 'stopped' WHERE status IN ('pending', 'streaming')",
      );
      // 新建后什么都没做的空会话（如离开前 App 被杀）。与 ChatService.discardIfEmpty 一致。
      await customStatement(
        // 以及「新对话追问」打开后一条都没发（离开前 App 被杀）的追问对话。
        "DELETE FROM conversations WHERE pinned = 0 AND ("
        "(participants_json = '[]' AND title = '新对话') "
        "OR title LIKE '追问：%') AND NOT EXISTS "
        '(SELECT 1 FROM messages m WHERE m.conversation_id = conversations.id)',
      );
    },
  );

  // ---------- 会话 ----------

  /// 会话列表：置顶在前，其余按更新时间倒序。
  Stream<List<Conversation>> watchConversations() {
    return (select(conversations)..orderBy([
          (c) => OrderingTerm.desc(c.pinned),
          (c) => OrderingTerm.desc(c.updatedAt),
        ]))
        .watch();
  }

  Future<void> deleteConversation(String id) {
    return (delete(conversations)..where((c) => c.id.equals(id))).go();
  }

  // ---------- 消息 ----------

  /// 会话内消息按时间、再按插入顺序（rowid）排列。
  /// drift 默认按秒存时间，同一秒内的消息必须靠 rowid 区分先后。
  SimpleSelectStatement<$MessagesTable, Message> _orderedMessages(
    String conversationId,
  ) {
    return select(messages)
      ..where((m) => m.conversationId.equals(conversationId))
      ..orderBy([
        (m) => OrderingTerm.asc(m.createdAt),
        (_) => OrderingTerm.asc(const CustomExpression<int>('rowid')),
      ]);
  }

  Stream<List<Message>> watchMessages(String conversationId) =>
      _orderedMessages(conversationId).watch();

  Future<List<Message>> messagesOf(String conversationId) =>
      _orderedMessages(conversationId).get();

  /// 插入消息并刷新所属会话的更新时间。
  Future<void> addMessage(MessagesCompanion message) {
    return transaction(() async {
      await into(messages).insert(message);
      await (update(conversations)
            ..where((c) => c.id.equals(message.conversationId.value)))
          .write(ConversationsCompanion(updatedAt: Value(DateTime.now())));
    });
  }
}
