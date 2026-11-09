import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../core/chat/chat_types.dart';
import '../db/app_database.dart';
import '../image_store.dart';
import 'cloud_store.dart';
import '../../l10n/tr.dart';

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SyncReport {
  int pulled = 0;
  int pushed = 0;
  int deleted = 0;

  @override
  String toString() =>
      trArgs('收到 {0} 项，上传 {1} 项，删除 {2} 项', [pulled, pushed, deleted]);
}

/// 一张同步表：表名、drift 表、把 JSON 行写入（存在则更新）。
class _Kind {
  _Kind(this.name, this.table, this.upsert);
  final String name;
  final TableInfo table;
  final Future<void> Function(Map<String, dynamic> row) upsert;
}

/// 远端某条记录的最新状态。
class _Version {
  const _Version(this.ts, {this.deleted = false});
  final int ts;
  final bool deleted;
}

/// iCloud 同步的合并引擎。
///
/// 云端目录结构（相对同步根）：
/// - `devices/<设备>.json`：该设备当前所有记录的版本号（modified_at）和删除记录。
///   每台设备只写自己的文件，不会互相覆盖。
/// - `records/<表>/<id>@<版本>.json`：某条记录某个版本的内容，写入后不再修改；
///   对话连同全部消息作为一条记录。
/// - `blobs/<文件名>`：图片和附件（文件名本身是 UUID，不会重复）。
///
/// 合并规则：每条记录取所有设备里版本号最大的（删除也算一个版本），
/// 即同一条记录在两台设备上都改过时，后改的为准。
class SyncEngine {
  SyncEngine(
    this._db,
    this._cloud,
    this._images, {
    required this.deviceId,
    this.deviceName = '',
  });

  final AppDatabase _db;
  final CloudStore _cloud;
  final ImageStore _images;
  final String deviceId;
  final String deviceName;

  static const formatVersion = 1;

  /// 按外键依赖排好的顺序：先写被引用的表，删除时倒过来。
  late final List<_Kind> _kinds = [
    _Kind(
      'folders',
      _db.folders,
      (j) => _db.into(_db.folders).insertOnConflictUpdate(Folder.fromJson(j)),
    ),
    _Kind(
      'channels',
      _db.channels,
      (j) => _db.into(_db.channels).insertOnConflictUpdate(Channel.fromJson(j)),
    ),
    _Kind(
      'models',
      _db.models,
      (j) => _db.into(_db.models).insertOnConflictUpdate(Model.fromJson(j)),
    ),
    _Kind(
      'model_routes',
      _db.modelRoutes,
      (j) => _db
          .into(_db.modelRoutes)
          .insertOnConflictUpdate(ModelRoute.fromJson(j)),
    ),
    _Kind(
      'agents',
      _db.agents,
      (j) => _db.into(_db.agents).insertOnConflictUpdate(Agent.fromJson(j)),
    ),
    _Kind(
      'prompts',
      _db.prompts,
      (j) => _db.into(_db.prompts).insertOnConflictUpdate(Prompt.fromJson(j)),
    ),
    _Kind(
      'conversations',
      _db.conversations,
      (j) => _db
          .into(_db.conversations)
          .insertOnConflictUpdate(Conversation.fromJson(j)),
    ),
  ];

  static String _key(String kind, String id) => '$kind/$id';
  static String _recordPath(String kind, String id, int ts) =>
      'records/$kind/$id@$ts.json';

  Future<SyncReport> sync() async {
    if (!await _cloud.available()) {
      throw SyncException(
        tr('iCloud 不可用：请确认已登录 iCloud，并在系统设置里为本 App 打开 iCloud 云盘'),
      );
    }
    final report = SyncReport();
    final (local, tombs) = await _localState();
    final remote = await _remoteState();

    // 1. 拉取：远端比本地新的记录。
    final toPull = <String, _Version>{};
    remote.forEach((key, v) {
      final mine = math.max(local[key] ?? -1, tombs[key] ?? -1);
      if (v.ts > mine) toPull[key] = v;
    });
    await _cloud.prefetch([
      for (final MapEntry(:key, :value) in toPull.entries)
        if (!value.deleted) _pathOf(key, value.ts),
    ]);
    for (final kind in _kinds) {
      for (final MapEntry(:key, :value) in toPull.entries) {
        if (value.deleted || !key.startsWith('${kind.name}/')) continue;
        final id = key.substring(kind.name.length + 1);
        if (await _pull(kind, id, value.ts)) {
          local[key] = value.ts;
          tombs.remove(key);
          report.pulled++;
        }
      }
    }
    for (final kind in _kinds.reversed) {
      for (final MapEntry(:key, :value) in toPull.entries) {
        if (!value.deleted || !key.startsWith('${kind.name}/')) continue;
        final id = key.substring(kind.name.length + 1);
        if (await _applyDelete(kind, id, value.ts)) report.deleted++;
        local.remove(key);
        tombs[key] = value.ts;
      }
    }
    if (report.pulled + report.deleted > 0) {
      _db.notifyUpdates({
        for (final k in _kinds) TableUpdate.onTable(k.table),
        TableUpdate.onTable(_db.messages),
      });
    }

    // 2. 推送：本地有、云端还没有的版本。
    final blobs = {for (final e in await _cloud.list('blobs')) e.name};
    for (final kind in _kinds) {
      final existing = {
        for (final e in await _cloud.list('records/${kind.name}')) e.name,
      };
      for (final MapEntry(:key, value: ts) in local.entries) {
        if (!key.startsWith('${kind.name}/')) continue;
        final id = key.substring(kind.name.length + 1);
        if (existing.contains('$id@$ts.json')) continue;
        final payload = await _payload(kind, id, blobs);
        if (payload == null) continue;
        await _cloud.write(
          _recordPath(kind.name, id, ts),
          Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        );
        report.pushed++;
      }
    }

    // 3. 写自己的索引。
    await _cloud.write(
      'devices/$deviceId.json',
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': formatVersion,
            'device': deviceId,
            'name': deviceName,
            'updated': DateTime.now().millisecondsSinceEpoch,
            'records': local,
            'tombstones': tombs,
          }),
        ),
      ),
    );

    // 4. 清理已被新版本取代的旧版本文件。
    await _collectGarbage(local, tombs, remote);
    return report;
  }

  String _pathOf(String key, int ts) {
    final i = key.indexOf('/');
    return _recordPath(key.substring(0, i), key.substring(i + 1), ts);
  }

  Future<(Map<String, int>, Map<String, int>)> _localState() async {
    final local = <String, int>{};
    for (final k in _kinds) {
      final rows = await _db
          .customSelect('SELECT id, modified_at FROM ${k.name}')
          .get();
      for (final r in rows) {
        local[_key(k.name, r.read<String>('id'))] =
            r.readNullable<int>('modified_at') ?? 0;
      }
    }
    final tombs = <String, int>{
      for (final t in await _db.select(_db.tombstones).get())
        _key(t.kind, t.id): t.deletedAt,
    };
    return (local, tombs);
  }

  /// 其它设备的索引合并成每条记录的最新版本。
  Future<Map<String, _Version>> _remoteState() async {
    final out = <String, _Version>{};
    void offer(String key, _Version v) {
      final cur = out[key];
      if (cur == null || v.ts > cur.ts) out[key] = v;
    }

    final devices = await _cloud.list('devices');
    await _cloud.prefetch([
      for (final d in devices)
        if (d.name != '$deviceId.json') 'devices/${d.name}',
    ]);
    for (final d in devices) {
      if (d.name == '$deviceId.json' || !d.name.endsWith('.json')) continue;
      final bytes = await _cloud.read('devices/${d.name}');
      if (bytes == null) continue;
      final Map<String, dynamic> j;
      try {
        j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if ((j['v'] as num? ?? 0) > formatVersion) {
        throw SyncException(tr('其它设备上的 App 版本更新，请先把这台设备的 App 升级到最新版'));
      }
      (j['records'] as Map? ?? const {}).forEach((k, v) {
        if (v is num) offer(k as String, _Version(v.toInt()));
      });
      (j['tombstones'] as Map? ?? const {}).forEach((k, v) {
        if (v is num) offer(k as String, _Version(v.toInt(), deleted: true));
      });
    }
    return out;
  }

  Future<Map<String, dynamic>?> _rowJson(_Kind kind, String id) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM ${kind.name} WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final data = await kind.table.map(row.data);
    return (data as DataClass).toJson();
  }

  /// 某条记录当前版本的内容；对话附带全部消息，并把用到的图片 / 附件传到 blobs。
  Future<Map<String, dynamic>?> _payload(
    _Kind kind,
    String id,
    Set<String> blobs,
  ) async {
    final row = await _rowJson(kind, id);
    if (row == null) return null;
    if (kind.name != 'conversations') return {'v': formatVersion, 'row': row};
    final messages = await _db.messagesOf(id);
    for (final m in messages) {
      for (final name in _blobNames(m.partsJson)) {
        if (blobs.contains(name)) continue;
        final bytes = await _images.readBytes(name);
        if (bytes == null) continue;
        await _cloud.write('blobs/$name', bytes);
        blobs.add(name);
      }
    }
    return {
      'v': formatVersion,
      'row': row,
      'messages': [for (final m in messages) m.toJson()],
    };
  }

  static Iterable<String> _blobNames(String partsJson) sync* {
    for (final p in ContentPart.decodeList(partsJson)) {
      switch (p) {
        case ImagePart(:final path):
          yield path;
        case FilePart(:final path):
          yield path;
        default:
      }
    }
  }

  /// 导入一条远端记录。内容文件还没同步到时返回 false（下次再试）。
  Future<bool> _pull(_Kind kind, String id, int ts) async {
    final bytes = await _cloud.read(_recordPath(kind.name, id, ts));
    if (bytes == null) return false;
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    final row = payload['row'];
    if (row is! Map<String, dynamic>) return false;

    try {
      if (kind.name == 'conversations') {
        // 本机这个对话正在生成回答：这轮先不覆盖。
        final active = await _db
            .customSelect(
              "SELECT 1 FROM messages WHERE conversation_id = ? "
              "AND status IN ('pending', 'streaming') LIMIT 1",
              variables: [Variable(id)],
            )
            .getSingleOrNull();
        if (active != null) return false;
        final messages = [
          for (final m in (payload['messages'] as List? ?? const []))
            Message.fromJson(m as Map<String, dynamic>),
        ];
        for (final m in messages) {
          for (final name in _blobNames(m.partsJson)) {
            if (await _images.readBytes(name) != null) continue;
            final blob = await _cloud.read('blobs/$name');
            if (blob != null) {
              await (await _images.file(name)).writeAsBytes(blob);
            }
          }
        }
        await _db.transaction(() async {
          await _db
              .into(_db.conversations)
              .insertOnConflictUpdate(Conversation.fromJson(row));
          await (_db.delete(
            _db.messages,
          )..where((m) => m.conversationId.equals(id))).go();
          for (final m in messages) {
            await _db.into(_db.messages).insertOnConflictUpdate(m);
          }
          await _setVersion(kind.name, id, ts);
        });
      } else {
        await _db.transaction(() async {
          await kind.upsert(row);
          await _setVersion(kind.name, id, ts);
        });
      }
    } catch (_) {
      // 依赖的记录（如渠道）还没到、或数据格式不兼容：跳过，下次再试。
      return false;
    }
    return true;
  }

  /// 把版本号设成远端的值。值不同才写：相同时更新触发器会把它改成「现在」，
  /// 让这条记录看起来像本地新改的，在设备间来回同步。
  Future<void> _setVersion(
    String table,
    String id,
    int ts,
  ) => _db.customStatement(
    'UPDATE $table SET modified_at = ? WHERE id = ? AND modified_at IS NOT ?',
    [ts, id, ts],
  );

  Future<bool> _applyDelete(_Kind kind, String id, int ts) async {
    var existed = false;
    await _db.transaction(() async {
      if (kind.name == 'conversations') {
        final msgs = await _db.messagesOf(id);
        for (final m in msgs) {
          for (final name in _blobNames(m.partsJson)) {
            await _images.delete(name);
          }
        }
      }
      existed =
          await _db
              .customSelect(
                'SELECT 1 FROM ${kind.name} WHERE id = ?',
                variables: [Variable(id)],
              )
              .getSingleOrNull() !=
          null;
      await _db.customStatement('DELETE FROM ${kind.name} WHERE id = ?', [id]);
      await _db.customStatement(
        'INSERT OR REPLACE INTO tombstones (kind, id, deleted_at) '
        'VALUES (?, ?, ?)',
        [kind.name, id, ts],
      );
    });
    return existed;
  }

  Future<void> _collectGarbage(
    Map<String, int> local,
    Map<String, int> tombs,
    Map<String, _Version> remote,
  ) async {
    for (final kind in _kinds) {
      for (final e in await _cloud.list('records/${kind.name}')) {
        final m = RegExp(r'^(.+)@(\d+)\.json$').firstMatch(e.name);
        if (m == null) continue;
        final key = _key(kind.name, m[1]!);
        final ts = int.parse(m[2]!);
        final newest = [
          local[key] ?? -1,
          tombs[key] ?? -1,
          remote[key]?.ts ?? -1,
        ].reduce(math.max);
        // 只删比已知最新版本旧的；比索引里更新的文件可能是别的设备刚写的，保留。
        if (ts < newest || (tombs[key] ?? -1) >= ts) {
          await _cloud.delete('records/${kind.name}/${e.name}');
        }
      }
    }
  }
}
