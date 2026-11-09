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
    Folders,
    Tombstones,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'agent'));

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _seedPrompts();
      await SyncSchema.install(this);
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
      if (from < 6) {
        await m.addColumn(channels, channels.modifiedAt);
        await m.addColumn(models, models.modifiedAt);
        await m.addColumn(modelRoutes, modelRoutes.modifiedAt);
        await m.addColumn(agents, agents.modifiedAt);
        await m.addColumn(conversations, conversations.modifiedAt);
        await m.addColumn(prompts, prompts.modifiedAt);
        await m.addColumn(conversations, conversations.folderId);
        await m.createTable(folders);
        await m.createTable(tombstones);
        for (final t in SyncSchema.tables) {
          await customStatement(
            'UPDATE $t SET modified_at = ${SyncSchema.nowMs}',
          );
        }
        await SyncSchema.install(this);
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

  // ---------- 文件夹 ----------

  Stream<List<Folder>> watchFolders() => (select(
    folders,
  )..orderBy([(f) => OrderingTerm.asc(f.sortOrder)])).watch();

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

/// iCloud 同步的数据库约定：每张同步表有 modified_at（毫秒），由触发器在插入 /
/// 修改时自动更新；删除时写入 tombstones。消息不单独同步，任何消息变化都会
/// 刷新所属对话的 modified_at，以对话为单位同步。
///
/// 同步导入时显式写入远端的 modified_at：更新触发器只在 modified_at 没被改动时
/// 才盖上当前时间，所以导入的时间戳会原样保留。
abstract final class SyncSchema {
  static const tables = [
    'channels',
    'models',
    'model_routes',
    'agents',
    'conversations',
    'prompts',
    'folders',
  ];

  static const nowMs =
      "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

  static Future<void> install(GeneratedDatabase db) async {
    for (final t in tables) {
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS sync_ins_$t AFTER INSERT ON $t BEGIN '
        'UPDATE $t SET modified_at = $nowMs '
        'WHERE id = NEW.id AND NEW.modified_at IS NULL; '
        "DELETE FROM tombstones WHERE kind = '$t' AND id = NEW.id; END",
      );
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS sync_upd_$t AFTER UPDATE ON $t '
        'WHEN NEW.modified_at IS OLD.modified_at BEGIN '
        'UPDATE $t SET modified_at = $nowMs WHERE id = NEW.id; END',
      );
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS sync_del_$t AFTER DELETE ON $t BEGIN '
        'INSERT OR REPLACE INTO tombstones (kind, id, deleted_at) '
        "VALUES ('$t', OLD.id, $nowMs); END",
      );
    }
    for (final (op, row) in [
      ('INSERT', 'NEW'),
      ('UPDATE', 'NEW'),
      ('DELETE', 'OLD'),
    ]) {
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS sync_msg_${op.toLowerCase()} '
        'AFTER $op ON messages BEGIN '
        'UPDATE conversations SET modified_at = $nowMs '
        'WHERE id = $row.conversation_id; END',
      );
    }
  }
}
