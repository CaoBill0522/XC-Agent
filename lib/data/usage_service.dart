import 'dart:convert';

import 'package:drift/drift.dart';

import 'db/app_database.dart';
import '../l10n/tr.dart';

/// 一组用量汇总（全部 / 某个模型 / 某个渠道）。
class UsageTotal {
  int requests = 0;
  int input = 0;
  int output = 0;

  void add(int inTok, int outTok) {
    requests++;
    input += inTok;
    output += outTok;
  }
}

typedef UsageRow = ({String id, String label, UsageTotal usage});

class UsageReport {
  UsageReport({
    required this.total,
    required this.byModel,
    required this.byChannel,
  });

  final UsageTotal total;

  /// 按模型 / 渠道汇总，按 token 总量从多到少排序。
  final List<UsageRow> byModel;
  final List<UsageRow> byChannel;
}

/// 用量统计：汇总助手回答里记录的 token 用量。
class UsageService {
  UsageService(this._db);

  final AppDatabase _db;

  Future<UsageReport> report({DateTime? since}) async {
    final q = _db.select(_db.messages)
      ..where((m) {
        final base = m.role.equals('assistant') & m.usageJson.isNotNull();
        return since == null
            ? base
            : base & m.createdAt.isBiggerOrEqualValue(since);
      });
    final msgs = await q.get();
    final models = {
      for (final m in await _db.select(_db.models).get()) m.id: m,
    };
    final channels = {
      for (final c in await _db.select(_db.channels).get()) c.id: c,
    };

    final total = UsageTotal();
    final byModel = <String, UsageTotal>{};
    final byChannel = <String, UsageTotal>{};
    final modelLabels = <String, String>{};
    for (final m in msgs) {
      final (inTok, outTok) = parseUsage(m.usageJson);
      if (inTok == 0 && outTok == 0) continue;
      final model = models[m.modelId];
      total.add(inTok, outTok);
      final mk = m.modelId ?? '?';
      modelLabels[mk] = model?.displayName ?? m.upstreamModel ?? tr('已删除的模型');
      byModel.putIfAbsent(mk, UsageTotal.new).add(inTok, outTok);
      byChannel
          .putIfAbsent(m.channelId ?? '?', UsageTotal.new)
          .add(inTok, outTok);
    }

    List<UsageRow> sorted(
      Map<String, UsageTotal> map,
      String Function(String id) label,
    ) =>
        [
          for (final e in map.entries)
            (id: e.key, label: label(e.key), usage: e.value),
        ]..sort(
          (a, b) => (b.usage.input + b.usage.output).compareTo(
            a.usage.input + a.usage.output,
          ),
        );

    return UsageReport(
      total: total,
      byModel: sorted(byModel, (id) => modelLabels[id] ?? id),
      byChannel: sorted(byChannel, (id) => channels[id]?.name ?? tr('已删除的渠道')),
    );
  }

  static (int, int) parseUsage(String? json) {
    try {
      final j = jsonDecode(json ?? '{}') as Map<String, dynamic>;
      return (
        (j['input'] as num?)?.toInt() ?? 0,
        (j['output'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return (0, 0);
    }
  }
}

/// 1234 → 1.2k，1234567 → 1.23M。
String formatTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1e6) return '${(n / 1e3).toStringAsFixed(n < 1e4 ? 1 : 0)}k';
  return '${(n / 1e6).toStringAsFixed(2)}M';
}
