import 'package:drift/drift.dart';

import '../../core/chat/chat_types.dart';
import '../db/app_database.dart';
import '../ids.dart';

/// 助手：名称 + 默认模型 + 系统提示词 + 生成参数。
class AgentRepository {
  AgentRepository(this._db);

  final AppDatabase _db;

  Stream<List<Agent>> watchAll() =>
      (_db.select(_db.agents)..orderBy([
            (a) => OrderingTerm.asc(a.sortOrder),
            (a) => OrderingTerm.asc(a.name),
          ]))
          .watch();

  Future<Agent?> get(String id) =>
      (_db.select(_db.agents)..where((a) => a.id.equals(id))).getSingleOrNull();

  Future<String> save({
    String? id,
    required String name,
    String? modelId,
    String? avatar,
    required String systemPrompt,
    required GenParams params,
  }) async {
    final agentId = id ?? newId();
    final data = AgentsCompanion(
      id: Value(agentId),
      name: Value(name.trim().isEmpty ? '未命名助手' : name.trim()),
      modelId: Value(modelId),
      avatar: Value(avatar),
      systemPrompt: Value(systemPrompt),
      paramsJson: Value(params.toJson()),
    );
    await _db.into(_db.agents).insertOnConflictUpdate(data);
    return agentId;
  }

  Future<void> delete(String id) =>
      (_db.delete(_db.agents)..where((a) => a.id.equals(id))).go();
}
