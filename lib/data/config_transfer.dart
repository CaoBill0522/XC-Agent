import 'dart:convert';
import 'dart:io' show gzip;

import 'db/app_database.dart';
import 'secure/key_store.dart';
import '../l10n/tr.dart';

/// 配置导入导出：渠道、模型、路由、助手（不含聊天记录）。
class ConfigTransfer {
  ConfigTransfer(this._db, this._keys);

  final AppDatabase _db;
  final KeyStore _keys;

  static const format = 'cn.oxoz.agent/config';
  static const version = 1;

  /// 导出文本的前缀：后面是 gzip 压缩后的 JSON 再做 base64url 编码。
  /// 这只是编码（防止一眼看到 Key、也更短），不是加密，任何人都能解开。
  static const prefix = 'XCAGENT1:';

  /// 导出全部配置（含 API Key），编码成一串文本。
  Future<String> export() async {
    final channels = await _db.select(_db.channels).get();
    final keys = <String, String>{};
    for (final c in channels) {
      final k = await _keys.read(c.id);
      if (k != null && k.isNotEmpty) keys[c.id] = k;
    }
    final json = jsonEncode({
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
    return prefix + base64Url.encode(gzip.encode(utf8.encode(json)));
  }

  /// 解码导出文本；也接受旧版直接导出的 JSON。
  static Map<String, dynamic> decode(String text) {
    final t = text.trim();
    try {
      final raw = t.startsWith(prefix)
          ? utf8.decode(
              gzip.decode(
                base64Url.decode(
                  base64Url.normalize(
                    t.substring(prefix.length).replaceAll(RegExp(r'\s'), ''),
                  ),
                ),
              ),
            )
          : t;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw FormatException(tr('剪贴板内容不是有效的配置'));
    }
  }

  /// 导入（按 ID 覆盖同名记录）。返回导入的条目数说明。
  Future<String> import(String text) async {
    final json = decode(text);
    if (json['format'] != format) throw FormatException(tr('不是本应用导出的配置'));

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
    return trArgs('已导入 {0} 个渠道（含 {1} 个 Key）、{2} 个模型、{3} 个助手', [
      channels.length,
      keys,
      models.length,
      agents.length,
    ]);
  }

  Future<void> clearChats() => _db.transaction(() async {
    await _db.delete(_db.messages).go();
    await _db.delete(_db.conversations).go();
  });
}
