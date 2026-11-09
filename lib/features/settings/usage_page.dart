import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/usage_service.dart';
import '../../ui/motion.dart';
import '../../ui/settings_widgets.dart';
import '../../l10n/tr.dart';

/// 统计区间。
enum UsagePeriod {
  today('今天'),
  week('近 7 天'),
  month('近 30 天'),
  all('全部');

  const UsagePeriod(this._label);
  final String _label;
  String get label => tr(_label);

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

/// 用量统计：请求次数和 token 用量，按模型、按渠道汇总。
class UsagePage extends ConsumerStatefulWidget {
  const UsagePage({super.key});

  @override
  ConsumerState<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends ConsumerState<UsagePage> {
  UsagePeriod _period = UsagePeriod.month;
  Future<UsageReport>? _report;

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

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    // 模型改名 / 删除后重新统计。
    ref.listen(modelsProvider, (_, _) => setState(_reload));

    String detail(UsageTotal u) => trArgs('{0} 次 · 输入 {1} · 输出 {2}', [
      u.requests,
      formatTokens(u.input),
      formatTokens(u.output),
    ]);

    return SettingsScaffold(
      title: tr('用量统计'),
      children: [
        SettingsGroup(
          children: [
            MiuixOverlayDropdownPreference(
              title: tr('统计区间'),
              items: [for (final p in UsagePeriod.values) p.label],
              selectedIndex: UsagePeriod.values.indexOf(_period),
              onSelectedIndexChange: (i) => setState(() {
                _period = UsagePeriod.values[i];
                _reload();
              }),
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
                        _Summary(total: r.total, period: _period.label),
                        if (r.byModel.isNotEmpty)
                          SettingsGroup(
                            title: tr('按模型'),
                            children: [
                              for (final row in r.byModel)
                                MiuixBasicComponent(
                                  title: row.label,
                                  summary: detail(row.usage),
                                ),
                            ],
                          ),
                        if (r.byChannel.isNotEmpty)
                          SettingsGroup(
                            title: tr('按渠道'),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
          child: MiuixText(
            tr('只统计模型返回了用量的请求，仅供参考。'),
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.total, required this.period});

  final UsageTotal total;
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
              cell('${total.requests}', tr('请求')),
              cell(formatTokens(total.input), tr('输入')),
              cell(formatTokens(total.output), tr('输出')),
            ],
          ),
        ),
      ],
    );
  }
}
