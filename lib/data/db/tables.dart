import 'package:drift/drift.dart';

/// 渠道：一个 API 接入点（厂商官方或中转站）。
/// API Key 不存这里，存在系统安全存储里，以 [id] 为索引。
class Channels extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// 预设 ID（openai / anthropic / xai / zhipu / deepseek / custom）。
  TextColumn get presetId => text().withDefault(const Constant('custom'))();

  /// 协议：openai_chat / openai_responses / anthropic。
  TextColumn get protocol => text()();
  TextColumn get baseUrl => text()();

  /// 额外请求头，JSON 对象。
  TextColumn get headersJson => text().withDefault(const Constant('{}'))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  /// 同步用的修改时间（毫秒时间戳，v6），由数据库触发器自动维护，见 SyncSchema。
  IntColumn get modifiedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 逻辑模型：用户在界面上选择的模型，下面挂多条 [ModelRoutes]。
class Models extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();

  /// 同名合并键：小写、去掉 `vendor/` 前缀。不同渠道拉到的同名模型归到同一个逻辑模型。
  /// （schema v2 新增）
  TextColumn get matchKey => text().withDefault(const Constant(''))();

  /// 能力标签，JSON 数组：vision / image_gen / reasoning / web_search / tools。
  TextColumn get capabilitiesJson => text().withDefault(const Constant('[]'))();

  /// 路由策略：round_robin / weighted / failover。
  TextColumn get routeStrategy =>
      text().withDefault(const Constant('round_robin'))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// （v5 加入的单价，已不再使用；保留列以免再做一次迁移。）
  RealColumn get inputPrice => real().nullable()();
  RealColumn get outputPrice => real().nullable()();

  /// 同步用的修改时间（毫秒时间戳，v6），由数据库触发器自动维护，见 SyncSchema。
  IntColumn get modifiedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 逻辑模型 → 渠道 的路由，同一模型可有多条，用于轮询/主备。
class ModelRoutes extends Table {
  TextColumn get id => text()();
  TextColumn get modelId =>
      text().references(Models, #id, onDelete: KeyAction.cascade)();
  TextColumn get channelId =>
      text().references(Channels, #id, onDelete: KeyAction.cascade)();

  /// 该渠道上的实际模型名。
  TextColumn get upstreamModel => text()();
  IntColumn get weight => integer().withDefault(const Constant(1))();
  IntColumn get priority => integer().withDefault(const Constant(0))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// 同步用的修改时间（毫秒时间戳，v6），由数据库触发器自动维护，见 SyncSchema。
  IntColumn get modifiedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 助手预设。
class Agents extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get avatar => text().nullable()();
  TextColumn get modelId => text().nullable()();
  TextColumn get systemPrompt => text().withDefault(const Constant(''))();

  /// 采样参数等，JSON 对象（temperature / top_p / max_tokens / reasoning_effort ...）。
  TextColumn get paramsJson => text().withDefault(const Constant('{}'))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 同步用的修改时间（毫秒时间戳，v6），由数据库触发器自动维护，见 SyncSchema。
  IntColumn get modifiedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();

  /// single / multi
  TextColumn get mode => text().withDefault(const Constant('single'))();

  /// （v1 遗留，未使用）
  TextColumn get agentIdsJson => text().withDefault(const Constant('[]'))();

  /// 参与者 JSON 数组：[{"modelId": "...", "agentId": "..."}]。单聊 1 个，多 Agent 多个。（v3）
  TextColumn get participantsJson => text().withDefault(const Constant('[]'))();

  /// 本会话是否开启联网搜索。（v3）
  BoolColumn get webSearch => boolean().withDefault(const Constant(false))();

  /// 会话选项 JSON（v5）：裁判 / 总结者、辩论轮数、上下文条数、自动压缩、
  /// 压缩后的早期对话摘要等，见 ConversationOptions。
  TextColumn get optionsJson => text().withDefault(const Constant('{}'))();

  /// 所在文件夹（v6），null = 未归档。
  TextColumn get folderId => text().nullable()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 同步用的修改时间（毫秒时间戳，v6），由数据库触发器自动维护，见 SyncSchema。
  IntColumn get modifiedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();

  /// 上一条消息（用于分支/重新生成）。
  TextColumn get parentId => text().nullable()();

  /// user / assistant / system
  TextColumn get role => text()();

  /// 内容块，JSON 数组：text / image / thinking / citation ...
  TextColumn get partsJson => text().withDefault(const Constant('[]'))();

  /// 多 Agent 模式下，同一问题的多个回答共享 groupId。
  TextColumn get groupId => text().nullable()();

  /// 接力分析模式下的步骤序号（0 起）；其他模式为 null。（schema v4）
  IntColumn get stepIndex => integer().nullable()();

  /// 特殊消息类型（v5）：judge = 裁判点评；debate = 辩论发言；summary = 辩论总结。
  TextColumn get kind => text().nullable()();

  /// 多 Agent 模式下是否为被采纳的回答（进入共同上下文）。
  BoolColumn get adopted => boolean().withDefault(const Constant(true))();
  TextColumn get agentId => text().nullable()();
  TextColumn get modelId => text().nullable()();

  /// 实际处理这次请求的渠道与上游模型名，方便排查。
  TextColumn get channelId => text().nullable()();
  TextColumn get upstreamModel => text().nullable()();

  /// pending / streaming / done / error / stopped
  TextColumn get status => text().withDefault(const Constant('done'))();
  TextColumn get error => text().nullable()();

  /// token 用量，JSON 对象。
  TextColumn get usageJson => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 提示词库：输入框里打 / 调出。（v5）
class Prompts extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get content => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 同步用的修改时间（毫秒时间戳，v6），由数据库触发器自动维护，见 SyncSchema。
  IntColumn get modifiedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 对话文件夹。（v6）
class Folders extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get modifiedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 删除记录（v6）：iCloud 同步时把删除传到其他设备。由触发器写入。
class Tombstones extends Table {
  /// 表名，如 conversations。
  TextColumn get kind => text()();
  TextColumn get id => text()();
  IntColumn get deletedAt => integer()();

  @override
  Set<Column> get primaryKey => {kind, id};
}
