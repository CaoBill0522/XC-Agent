import 'dart:math';

import '../../data/repositories/channel_repository.dart';

/// 路由策略。[id] 存进 Models.routeStrategy。
enum RouteStrategy {
  roundRobin('round_robin', '轮询', '依次使用每个渠道'),
  weighted('weighted', '加权随机', '按权重比例随机选择'),
  failover('failover', '主备', '按优先级，前一个失败才用下一个');

  const RouteStrategy(this.id, this.label, this.description);
  final String id;
  final String label;
  final String description;

  static RouteStrategy fromId(String id) =>
      values.firstWhere((s) => s.id == id, orElse: () => roundRobin);
}

class _Health {
  int consecutiveFailures = 0;
  DateTime? cooldownUntil;
}

/// 为逻辑模型挑选渠道顺序，并做简单熔断。
///
/// 返回的列表第一个是本次首选，其余是失败后的备选。
/// 连续失败 [failureThreshold] 次的渠道冷却 [cooldown]，冷却中的渠道排到最后（全部冷却时仍会尝试）。
class ModelRouter {
  ModelRouter({Random? random, DateTime Function()? now})
    : _random = random ?? Random(),
      _now = now ?? DateTime.now;

  static const failureThreshold = 3;
  static const cooldown = Duration(seconds: 60);

  final Random _random;
  final DateTime Function() _now;
  final _cursor = <String, int>{};
  final _health = <String, _Health>{};

  bool isCoolingDown(String channelId) {
    final until = _health[channelId]?.cooldownUntil;
    return until != null && _now().isBefore(until);
  }

  List<RouteInfo> order(ModelWithRoutes model) {
    final usable =
        [
          for (final r in model.routes)
            if (r.route.enabled && r.channel.enabled) r,
        ]..sort((a, b) {
          final p = a.route.priority.compareTo(b.route.priority);
          return p != 0 ? p : a.route.id.compareTo(b.route.id);
        });
    if (usable.length <= 1) return usable;

    final healthy = usable.where((r) => !isCoolingDown(r.channel.id)).toList();
    final cooling = usable.where((r) => isCoolingDown(r.channel.id)).toList();
    if (healthy.isEmpty) return usable;

    final ordered = switch (RouteStrategy.fromId(model.model.routeStrategy)) {
      RouteStrategy.failover => healthy,
      RouteStrategy.roundRobin => _rotate(model.model.id, healthy),
      RouteStrategy.weighted => _weighted(healthy),
    };
    return [...ordered, ...cooling];
  }

  List<RouteInfo> _rotate(String modelId, List<RouteInfo> list) {
    final start = (_cursor[modelId] ?? 0) % list.length;
    _cursor[modelId] = start + 1;
    return [...list.sublist(start), ...list.sublist(0, start)];
  }

  List<RouteInfo> _weighted(List<RouteInfo> list) {
    final total = list.fold<int>(0, (s, r) => s + max(r.route.weight, 0));
    if (total <= 0) return list;
    var pick = _random.nextInt(total);
    for (final r in list) {
      pick -= max(r.route.weight, 0);
      if (pick < 0) return [r, ...list.where((x) => x != r)];
    }
    return list;
  }

  void reportSuccess(String channelId) => _health.remove(channelId);

  void reportFailure(String channelId) {
    final h = _health.putIfAbsent(channelId, _Health.new);
    h.consecutiveFailures++;
    if (h.consecutiveFailures >= failureThreshold) {
      h.cooldownUntil = _now().add(cooldown);
      h.consecutiveFailures = 0;
    }
  }
}
