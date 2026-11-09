import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Channels,
    Models,
    ModelRoutes,
    Agents,
    Conversations,
    Messages,
    Prompts,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'agent'));

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _seedPrompts();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.addColumn(models, models.matchKey);
      if (from < 3) {
        await m.addColumn(conversations, conversations.participantsJson);
        await m.addColumn(conversations, conversations.webSearch);
      }
      if (from < 4) await m.addColumn(messages, messages.stepIndex);
      if (from < 5) {
        await m.addColumn(models, models.inputPrice);
        await m.addColumn(models, models.outputPrice);
        await m.addColumn(conversations, conversations.optionsJson);
        await m.addColumn(messages, messages.kind);
        await m.createTable(prompts);
        await _seedPrompts();
      }
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

  /// 内置的几条常用提示词，用户可以改删。
  static const defaultPrompts = [
    ('翻译成英文', '把下面的内容翻译成地道的英文，只输出译文：\n\n'),
    ('总结要点', '用几条要点总结下面的内容，每条一句话：\n\n'),
    ('检查代码', '检查下面的代码有没有 bug、边界情况和可以改进的地方，按严重程度列出：\n\n'),
    ('润色文字', '在不改变原意的前提下润色下面的文字，让它更通顺自然：\n\n'),
    ('通俗解释', '用通俗易懂的话解释下面的内容，必要时举个例子：\n\n'),
  ];

  Future<void> _seedPrompts() async {
    for (final (i, (title, content)) in defaultPrompts.indexed) {
      await into(prompts).insert(
        PromptsCompanion.insert(
          id: 'builtin-$i',
          title: title,
          content: content,
          sortOrder: Value(i),
        ),
      );
    }
  }

  // ---------- 提示词 ----------

  Stream<List<Prompt>> watchPrompts() => (select(
    prompts,
  )..orderBy([(p) => OrderingTerm.asc(p.sortOrder)])).watch();

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
