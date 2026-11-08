import 'dart:convert';

import 'db/app_database.dart';
import 'secure/key_store.dart';

/// 配置导入导出：渠道、模型、路由、助手（不含聊天记录）。
class ConfigTransfer {
  ConfigTransfer(this._db, this._keys);

  final AppDatabase _db;
  final KeyStore _keys;

  static const format = 'cn.oxoz.agent/config';
  static const version = 1;

  Future<String> export({required bool includeKeys}) async {
    final channels = await _db.select(_db.channels).get();
    final keys = <String, String>{};
    if (includeKeys) {
      for (final c in channels) {
        final k = await _keys.read(c.id);
        if (k != null && k.isNotEmpty) keys[c.id] = k;
      }
    }
    return const JsonEncoder.withIndent('  ').convert({
      'format': format,
      'version': version,
      'channels': [
        for (final c in channels) {...c.toJson(), 'apiKey': ?keys[c.id]},
      ],
      'models': [
        for (final m in await _db.select(_db.models).get()) m.toJson(),
      ],
      'routes': [
        for (final r in await _db.select(_db.modelRoutes).get()) r.toJson(),
      ],
      'agents': [
        for (final a in await _db.select(_db.agents).get()) a.toJson(),
      ],
    });
  }

  /// 导入（按 ID 覆盖同名记录）。返回导入的条目数说明。
  Future<String> import(String text) async {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('剪贴板内容不是有效的配置 JSON');
    }
    if (json['format'] != format) throw const FormatException('不是本应用导出的配置');

    List<Map<String, dynamic>> list(String k) => [
      for (final e in (json[k] as List? ?? const [])) e as Map<String, dynamic>,
    ];

    final channels = list('channels');
    final models = list('models');
    final routes = list('routes');
    final agents = list('agents');
    var keys = 0;

    await _db.transaction(() async {
      for (final c in channels) {
        await _db
            .into(_db.channels)
            .insertOnConflictUpdate(Channel.fromJson(c));
      }
      for (final m in models) {
        await _db.into(_db.models).insertOnConflictUpdate(Model.fromJson(m));
      }
      for (final r in routes) {
        await _db
            .into(_db.modelRoutes)
            .insertOnConflictUpdate(ModelRoute.fromJson(r));
      }
      for (final a in agents) {
        await _db.into(_db.agents).insertOnConflictUpdate(Agent.fromJson(a));
      }
    });
    for (final c in channels) {
      if (c['apiKey'] case final String k when k.isNotEmpty) {
        await _keys.write(c['id'] as String, k);
        keys++;
      }
    }
    return '已导入 ${channels.length} 个渠道（含 $keys 个 Key）、${models.length} 个模型、${agents.length} 个助手';
  }

  Future<void> clearChats() => _db.transaction(() async {
    await _db.delete(_db.messages).go();
    await _db.delete(_db.conversations).go();
  });
}
