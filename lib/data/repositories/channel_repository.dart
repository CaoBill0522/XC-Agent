import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/api/endpoint.dart';
import '../../core/api/protocol.dart';
import '../../core/models/capabilities.dart';
import '../db/app_database.dart';
import '../ids.dart';
import '../secure/key_store.dart';

class ChannelSummary {
  const ChannelSummary(this.channel, this.modelCount);

  final Channel channel;
  final int modelCount;

  ApiProtocol get protocol => ApiProtocol.fromId(channel.protocol);
}

class RouteInfo {
  const RouteInfo(this.route, this.channel);

  final ModelRoute route;
  final Channel channel;
}

class ModelWithRoutes {
  const ModelWithRoutes(this.model, this.routes);

  final Model model;
  final List<RouteInfo> routes;

  Set<ModelCapability> get capabilities =>
      ModelCapability.decode(model.capabilitiesJson);
}

/// 同名合并键：小写、去掉 `vendor/` 前缀。
String modelMatchKey(String upstreamModel) {
  final s = upstreamModel.trim().toLowerCase();
  final i = s.lastIndexOf('/');
  return i >= 0 ? s.substring(i + 1) : s;
}

class ChannelRepository {
  ChannelRepository(this._db, this._keys);

  final AppDatabase _db;
  final KeyStore _keys;

  // ──────────────── 渠道

  Stream<List<ChannelSummary>> watchChannels() {
    final count = _db.modelRoutes.id.count();
    final query =
        _db.select(_db.channels).join([
            leftOuterJoin(
              _db.modelRoutes,
              _db.modelRoutes.channelId.equalsExp(_db.channels.id),
              useColumns: false,
            ),
          ])
          ..addColumns([count])
          ..groupBy([_db.channels.id])
          ..orderBy([
            OrderingTerm.asc(_db.channels.sortOrder),
            OrderingTerm.asc(_db.channels.createdAt),
          ]);
    return query.watch().map(
      (rows) => [
        for (final r in rows)
          ChannelSummary(r.readTable(_db.channels), r.read(count) ?? 0),
      ],
    );
  }

  Future<Channel?> getChannel(String id) => (_db.select(
    _db.channels,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<String?> readApiKey(String channelId) => _keys.read(channelId);

  /// 新建（[id] 为空）或更新渠道，返回渠道 ID。
  Future<String> saveChannel({
    String? id,
    required String name,
    required String presetId,
    required ApiProtocol protocol,
    required String baseUrl,
    required String apiKey,
    Map<String, String> headers = const {},
  }) async {
    final channelId = id ?? newId();
    final normalized = ChannelEndpoint.normalizeBaseUrl(protocol, baseUrl);
    final data = ChannelsCompanion(
      name: Value(name.trim()),
      presetId: Value(presetId),
      protocol: Value(protocol.id),
      baseUrl: Value(normalized),
      headersJson: Value(jsonEncode(headers)),
    );
    if (id == null) {
      await _db
          .into(_db.channels)
          .insert(
            data.copyWith(
              id: Value(channelId),
              createdAt: Value(DateTime.now()),
            ),
          );
    } else {
      await (_db.update(
        _db.channels,
      )..where((c) => c.id.equals(id))).write(data);
    }
    await _keys.write(channelId, apiKey.trim());
    return channelId;
  }

  Future<void> setChannelEnabled(String id, bool enabled) =>
      (_db.update(_db.channels)..where((c) => c.id.equals(id))).write(
        ChannelsCompanion(enabled: Value(enabled)),
      );

  Future<void> deleteChannel(String id) async {
    await _db.transaction(() async {
      await (_db.delete(_db.channels)..where((c) => c.id.equals(id))).go();
      await _deleteOrphanModels();
    });
    await _keys.delete(id);
  }

  Future<ChannelEndpoint> endpointFor(Channel channel) async {
    final headers = <String, String>{};
    try {
      (jsonDecode(channel.headersJson) as Map).forEach(
        (k, v) => headers['$k'] = '$v',
      );
    } catch (_) {}
    return ChannelEndpoint(
      protocol: ApiProtocol.fromId(channel.protocol),
      baseUrl: channel.baseUrl,
      apiKey: await _keys.read(channel.id) ?? '',
      extraHeaders: headers,
    );
  }

  // ──────────────── 渠道下的模型

  /// 渠道当前已启用的上游模型名。
  Future<Set<String>> channelModelNames(String channelId) async {
    final routes = await (_db.select(
      _db.modelRoutes,
    )..where((r) => r.channelId.equals(channelId))).get();
    return {for (final r in routes) r.upstreamModel};
  }

  /// 把渠道的模型选择同步到数据库：
  /// - 新选中的：按合并键找已有逻辑模型，没有就新建（能力按名字推断），再挂一条路由；
  /// - 取消选中的：删掉该渠道的路由；
  /// - 没有任何路由的逻辑模型一并删除。
  Future<void> syncChannelModels(String channelId, Iterable<String> selected) {
    final wanted = {for (final s in selected) s.trim()}..remove('');
    return _db.transaction(() async {
      final existing = await (_db.select(
        _db.modelRoutes,
      )..where((r) => r.channelId.equals(channelId))).get();
      final existingNames = {for (final r in existing) r.upstreamModel};

      final toRemove = [
        for (final r in existing)
          if (!wanted.contains(r.upstreamModel)) r.id,
      ];
      if (toRemove.isNotEmpty) {
        await (_db.delete(
          _db.modelRoutes,
        )..where((r) => r.id.isIn(toRemove))).go();
      }

      for (final upstream in wanted.difference(existingNames)) {
        final modelId = await _findOrCreateModel(upstream);
        await _db
            .into(_db.modelRoutes)
            .insert(
              ModelRoutesCompanion.insert(
                id: newId(),
                modelId: modelId,
                channelId: channelId,
                upstreamModel: upstream,
              ),
            );
      }

      await _deleteOrphanModels();
    });
  }

  Future<String> _findOrCreateModel(String upstream) async {
    final key = modelMatchKey(upstream);
    final found =
        await (_db.select(_db.models)
              ..where((m) => m.matchKey.equals(key))
              ..limit(1))
            .getSingleOrNull();
    if (found != null) return found.id;

    final id = newId();
    final profile = inferModelProfile(upstream);
    // 显示名用去掉前缀后的名字（保留原大小写）。
    final slash = upstream.lastIndexOf('/');
    final display = slash >= 0 ? upstream.substring(slash + 1) : upstream;
    await _db
        .into(_db.models)
        .insert(
          ModelsCompanion.insert(
            id: id,
            displayName: display,
            matchKey: Value(key),
            capabilitiesJson: Value(
              ModelCapability.encode(profile.capabilities),
            ),
          ),
        );
    return id;
  }

  Future<void> _deleteOrphanModels() => _db.customStatement(
    'DELETE FROM models WHERE id NOT IN (SELECT DISTINCT model_id FROM model_routes)',
  );

  // ──────────────── 逻辑模型

  Stream<List<ModelWithRoutes>> watchModels() {
    final query =
        _db.select(_db.models).join([
          leftOuterJoin(
            _db.modelRoutes,
            _db.modelRoutes.modelId.equalsExp(_db.models.id),
          ),
          leftOuterJoin(
            _db.channels,
            _db.channels.id.equalsExp(_db.modelRoutes.channelId),
          ),
        ])..orderBy([
          OrderingTerm.asc(_db.models.sortOrder),
          OrderingTerm.asc(_db.models.displayName.lower()),
        ]);

    return query.watch().map((rows) {
      final byId = <String, ModelWithRoutes>{};
      for (final r in rows) {
        final model = r.readTable(_db.models);
        final entry = byId.putIfAbsent(
          model.id,
          () => ModelWithRoutes(model, []),
        );
        final route = r.readTableOrNull(_db.modelRoutes);
        final channel = r.readTableOrNull(_db.channels);
        if (route != null && channel != null) {
          entry.routes.add(RouteInfo(route, channel));
        }
      }
      return byId.values.toList();
    });
  }

  Future<void> updateModel(
    String id, {
    String? displayName,
    Set<ModelCapability>? capabilities,
    bool? enabled,
  }) {
    return (_db.update(_db.models)..where((m) => m.id.equals(id))).write(
      ModelsCompanion(
        displayName: displayName == null || displayName.trim().isEmpty
            ? const Value.absent()
            : Value(displayName.trim()),
        capabilitiesJson: capabilities == null
            ? const Value.absent()
            : Value(ModelCapability.encode(capabilities)),
        enabled: enabled == null ? const Value.absent() : Value(enabled),
      ),
    );
  }


  Future<void> setRouteStrategy(String modelId, String strategy) =>
      (_db.update(_db.models)..where((m) => m.id.equals(modelId))).write(
        ModelsCompanion(routeStrategy: Value(strategy)),
      );

  Future<void> updateRoute(
    String routeId, {
    bool? enabled,
    int? weight,
    int? priority,
  }) => (_db.update(_db.modelRoutes)..where((r) => r.id.equals(routeId))).write(
    ModelRoutesCompanion(
      enabled: enabled == null ? const Value.absent() : Value(enabled),
      weight: weight == null ? const Value.absent() : Value(weight),
      priority: priority == null ? const Value.absent() : Value(priority),
    ),
  );
}
