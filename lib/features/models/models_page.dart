import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/motion.dart';
import '../../core/models/capabilities.dart';
import '../../core/routing/model_router.dart';
import '../../data/providers.dart';
import '../../data/repositories/channel_repository.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/settings_widgets.dart';

/// 逻辑模型列表：同名模型已跨渠道合并。
class ModelsPage extends ConsumerWidget {
  const ModelsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final models = ref.watch(modelsProvider);

    return SettingsScaffold(
      title: '模型',
      children: [
        ...models.when(
          loading: () => [const SizedBox.shrink()],
          error: (e, _) => [Center(child: MiuixText('加载失败：$e'))],
          data: (items) => items.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 64,
                      horizontal: 32,
                    ),
                    child: MiuixText(
                      '还没有模型\n先在「渠道」里添加 API Key 并拉取模型',
                      textAlign: TextAlign.center,
                      color: colors.onSurfaceVariantSummary,
                    ),
                  ),
                ]
              : [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 4, 28, 8),
                    child: MiuixText(
                      '不同渠道的同名模型会自动合并，聊天时在这些渠道间轮询。',
                      fontSize: 13,
                      color: colors.onSurfaceVariantSummary,
                    ),
                  ),
                  SettingsGroup(
                    children: [
                      for (final m in items)
                        MiuixArrowPreference(
                          title: m.model.displayName,
                          summary: [
                            m.routes.length > 1
                                ? '${m.routes.length} 个渠道轮询'
                                : m.routes.firstOrNull?.channel.name ?? '无渠道',
                            if (!m.model.enabled) '已停用',
                          ].join(' · '),
                          bottomAction: m.capabilities.isEmpty
                              ? null
                              : Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: CapabilityBadges(m.capabilities),
                                ),
                          onClick: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  ModelDetailPage(modelId: m.model.id),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
        ),
      ],
    );
  }
}

class ModelDetailPage extends ConsumerStatefulWidget {
  const ModelDetailPage({super.key, required this.modelId});

  final String modelId;

  @override
  ConsumerState<ModelDetailPage> createState() => _ModelDetailPageState();
}

class _ModelDetailPageState extends ConsumerState<ModelDetailPage> {
  final _name = TextEditingController();
  bool _nameLoaded = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  ChannelRepository get _repo => ref.read(channelRepositoryProvider);

  static String _fmtPrice(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';

  Future<void> _editNumber(
    BuildContext context,
    String title,
    int current,
    ValueChanged<int> onSave,
  ) async {
    final v = await showTextInput(
      context,
      title: title,
      initial: '$current',
      autocorrect: false,
    );
    final n = int.tryParse(v?.trim() ?? '');
    if (n != null && n >= 0) onSave(n);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final m = ref
        .watch(modelsProvider)
        .value
        ?.where((m) => m.model.id == widget.modelId)
        .firstOrNull;
    if (m == null) return const SettingsScaffold(title: '模型', children: []);

    if (!_nameLoaded) {
      _nameLoaded = true;
      _name.text = m.model.displayName;
    }
    final caps = m.capabilities;
    final strategy = RouteStrategy.fromId(m.model.routeStrategy);
    final router = ref.read(modelRouterProvider);

    return SettingsScaffold(
      title: m.model.displayName,
      children: [
        SettingsGroup(
          title: '基本',
          children: [
            SettingsField(
              controller: _name,
              label: '显示名称',
              trailing: Tap(
                onTap: () {
                  FocusScope.of(context).unfocus();
                  _repo.updateModel(m.model.id, displayName: _name.text);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: MiuixText('保存', color: colors.primary, fontSize: 14),
                ),
              ),
            ),
            MiuixSwitchPreference(
              title: '启用',
              summary: '停用后不出现在聊天的模型选择里',
              value: m.model.enabled,
              onChanged: (v) => _repo.updateModel(m.model.id, enabled: v),
            ),
          ],
        ),
        SettingsGroup(
          title: '单价（每百万 token，用于用量统计）',
          children: [
            for (final (input, label) in [(true, '输入'), (false, '输出')])
              MiuixArrowPreference(
                title: '$label单价',
                summary: switch (input
                    ? m.model.inputPrice
                    : m.model.outputPrice) {
                  null => '未设置',
                  final v => _fmtPrice(v),
                },
                onClick: () async {
                  final cur = input ? m.model.inputPrice : m.model.outputPrice;
                  final v = await showTextInput(
                    context,
                    title: '$label单价（每百万 token）',
                    initial: cur == null ? '' : _fmtPrice(cur),
                    label: '留空表示未设置',
                    autocorrect: false,
                  );
                  if (v == null) return;
                  final price = double.tryParse(v.trim());
                  if (v.trim().isNotEmpty && (price == null || price < 0)) {
                    return;
                  }
                  await _repo.setModelPrice(
                    m.model.id,
                    input: input ? price : m.model.inputPrice,
                    output: input ? m.model.outputPrice : price,
                  );
                },
              ),
          ],
        ),
        SettingsGroup(
          title: '能力（按名称自动识别，可手动修改）',
          children: [
            for (final c in ModelCapability.values)
              MiuixSwitchPreference(
                title: c.label,
                summary: switch (c) {
                  ModelCapability.vision => '可以发送图片给它',
                  ModelCapability.imageGen => '可以生成图片',
                  ModelCapability.reasoning => '会输出思考过程',
                  ModelCapability.webSearch => '支持厂商原生联网搜索',
                },
                value: caps.contains(c),
                onChanged: (v) => _repo.updateModel(
                  m.model.id,
                  capabilities: v ? {...caps, c} : ({...caps}..remove(c)),
                ),
              ),
          ],
        ),
        if (m.routes.length > 1)
          SettingsGroup(
            title: '多渠道策略',
            children: [
              MiuixOverlayDropdownPreference(
                title: '路由策略',
                summary: strategy.description,
                items: [for (final s in RouteStrategy.values) s.label],
                selectedIndex: RouteStrategy.values.indexOf(strategy),
                onSelectedIndexChange: (i) => _repo.setRouteStrategy(
                  m.model.id,
                  RouteStrategy.values[i].id,
                ),
              ),
            ],
          ),
        SettingsGroup(
          title: '渠道（${m.routes.length}）',
          children: [
            for (final r in m.routes)
              MiuixBasicComponent(
                title: r.channel.name,
                summary: [
                  '上游：${r.route.upstreamModel}',
                  if (strategy == RouteStrategy.weighted)
                    '权重 ${r.route.weight}',
                  if (strategy == RouteStrategy.failover)
                    '优先级 ${r.route.priority}',
                  if (!r.channel.enabled) '渠道已停用',
                  if (router.isCoolingDown(r.channel.id)) '冷却中',
                ].join(' · '),
                startAction: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: MiuixIcon(
                    vector: AppIcons.link,
                    size: 20,
                    tint: colors.onSurfaceVariantActions,
                  ),
                ),
                endActions: [
                  MiuixSwitch(
                    value: r.route.enabled,
                    onChanged: (v) => _repo.updateRoute(r.route.id, enabled: v),
                  ),
                ],
                onClick: switch (strategy) {
                  RouteStrategy.weighted => () => _editNumber(
                    context,
                    '权重',
                    r.route.weight,
                    (v) => _repo.updateRoute(r.route.id, weight: v),
                  ),
                  RouteStrategy.failover => () => _editNumber(
                    context,
                    '优先级（数字越小越优先）',
                    r.route.priority,
                    (v) => _repo.updateRoute(r.route.id, priority: v),
                  ),
                  RouteStrategy.roundRobin => null,
                },
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 0),
          child: MiuixText(
            '请求失败（网络错误、Key 无效、限流、服务端错误）时自动换下一个渠道；'
            '连续失败 ${ModelRouter.failureThreshold} 次的渠道冷却 ${ModelRouter.cooldown.inSeconds} 秒。'
            '要彻底移除某个渠道，请到该渠道的「管理模型」里取消勾选。',
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
        ),
      ],
    );
  }
}
