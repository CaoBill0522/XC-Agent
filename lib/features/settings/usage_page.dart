import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_error.dart';
import '../../core/api/channel_client.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../data/usage_service.dart';
import '../../ui/motion.dart';
import '../../ui/settings_widgets.dart';
import '../models/models_page.dart';

const _currencyKey = 'usage_currency';

/// 统计区间。
enum UsagePeriod {
  today('今天'),
  week('近 7 天'),
  month('近 30 天'),
  all('全部');

  const UsagePeriod(this.label);
  final String label;

  DateTime? since(DateTime now) => switch (this) {
    today => DateTime(now.year, now.month, now.day),
    week => now.subtract(const Duration(days: 7)),
    month => now.subtract(const Duration(days: 30)),
    all => null,
  };
}

final usageServiceProvider = Provider<UsageService>(
  (ref) => UsageService(ref.watch(databaseProvider)),
);

/// 用量统计：token 用量与按单价估算的费用；中转站 / DeepSeek 可查余额。
class UsagePage extends ConsumerStatefulWidget {
  const UsagePage({super.key});

  @override
  ConsumerState<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends ConsumerState<UsagePage> {
  UsagePeriod _period = UsagePeriod.month;
  Future<UsageReport>? _report;
  final _balances = <String, String>{};
  final _loading = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _report = ref
        .read(usageServiceProvider)
        .report(since: _period.since(DateTime.now()));
  }

  String get _currency =>
      ref.read(prefsProvider).getString(_currencyKey) ?? r'$';

  String _money(double v) =>
      '$_currency${v < 0.01 && v > 0 ? v.toStringAsFixed(4) : v.toStringAsFixed(2)}';

  Future<void> _queryBalance(Channel c) async {
    setState(() => _loading.add(c.id));
    String text;
    try {
      final endpoint = await ref.read(channelRepositoryProvider).endpointFor(c);
      text = await ref
          .read(channelClientProvider)
          .balance(endpoint, c.presetId);
    } on ApiException catch (e) {
      text = e.message;
    } catch (e) {
      text = '查询失败：$e';
    }
    if (!mounted) return;
    setState(() {
      _loading.remove(c.id);
      _balances[c.id] = text;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final channels = ref.watch(channelsProvider).value ?? const [];
    // 单价、模型变化后重新统计。
    ref.listen(modelsProvider, (_, _) => setState(_reload));

    String detail(UsageTotal u) {
      final cost = u.requests == u.unpriced
          ? '未设置单价'
          : '${_money(u.cost)}${u.unpriced > 0 ? '（部分未设单价）' : ''}';
      return '${u.requests} 次 · 输入 ${formatTokens(u.input)} · '
          '输出 ${formatTokens(u.output)} · $cost';
    }

    return SettingsScaffold(
      title: '用量统计',
      children: [
        SettingsGroup(
          children: [
            MiuixOverlayDropdownPreference(
              title: '统计区间',
              items: [for (final p in UsagePeriod.values) p.label],
              selectedIndex: UsagePeriod.values.indexOf(_period),
              onSelectedIndexChange: (i) => setState(() {
                _period = UsagePeriod.values[i];
                _reload();
              }),
            ),
            MiuixOverlayDropdownPreference(
              title: '货币',
              summary: '模型单价使用的货币',
              items: const [r'美元 $', '人民币 ¥'],
              selectedIndex: _currency == '¥' ? 1 : 0,
              onSelectedIndexChange: (i) {
                ref
                    .read(prefsProvider)
                    .setString(_currencyKey, i == 1 ? '¥' : r'$');
                setState(() {});
              },
            ),
          ],
        ),
        FutureBuilder<UsageReport>(
          future: _report,
          builder: (context, snap) {
            final r = snap.data;
            return FadeSwitch(
              switchKey: r == null ? 'loading' : '${_period.name}-loaded',
              child: r == null
                  ? const SizedBox(height: 120, width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Summary(
                          total: r.total,
                          money: _money,
                          period: _period.label,
                        ),
                        if (r.byModel.isNotEmpty)
                          SettingsGroup(
                            title: '按模型（点击设置单价）',
                            children: [
                              for (final row in r.byModel)
                                MiuixArrowPreference(
                                  title: row.label,
                                  summary: detail(row.usage),
                                  onClick: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ModelDetailPage(modelId: row.id),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        if (r.byChannel.isNotEmpty)
                          SettingsGroup(
                            title: '按渠道',
                            children: [
                              for (final row in r.byChannel)
                                MiuixBasicComponent(
                                  title: row.label,
                                  summary: detail(row.usage),
                                ),
                            ],
                          ),
                      ],
                    ),
            );
          },
        ),
        if (channels.any(
          (c) => ChannelClient.supportsBalance(c.channel.presetId),
        ))
          SettingsGroup(
            title: '余额（DeepSeek 官方、New API / One API 中转站）',
            children: [
              for (final c in channels)
                if (ChannelClient.supportsBalance(c.channel.presetId))
                  MiuixBasicComponent(
                    title: c.channel.name,
                    summary: _loading.contains(c.channel.id)
                        ? '查询中…'
                        : _balances[c.channel.id] ?? '点击查询',
                    onClick: _loading.contains(c.channel.id)
                        ? null
                        : () => _queryBalance(c.channel),
                  ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
          child: MiuixText(
            '费用 = 输入 token × 输入单价 + 输出 token × 输出单价，单价在「模型」里按每百万 token 设置。'
            '只统计模型返回了用量的请求，仅供参考，以渠道账单为准。',
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.total,
    required this.money,
    required this.period,
  });

  final UsageTotal total;
  final String Function(double) money;
  final String period;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    Widget cell(String value, String label) => Expanded(
      child: Column(
        children: [
          MiuixText(value, fontSize: 18, fontWeight: FontWeight.w600),
          const SizedBox(height: 2),
          MiuixText(label, fontSize: 12, color: colors.onSurfaceVariantSummary),
        ],
      ),
    );
    return SettingsGroup(
      title: period,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Row(
            children: [
              cell('${total.requests}', '请求'),
              cell(formatTokens(total.input), '输入'),
              cell(formatTokens(total.output), '输出'),
              cell(
                total.requests > 0 && total.requests == total.unpriced
                    ? '—'
                    : money(total.cost),
                '费用',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
