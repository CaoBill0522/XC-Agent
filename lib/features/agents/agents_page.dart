import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/chat/chat_types.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/settings_widgets.dart';
import '../../ui/vendor/app_text_field.dart';
import '../../l10n/tr.dart';

/// 助手列表：每个助手 = 模型 + 系统提示词 + 参数。
class AgentsPage extends ConsumerWidget {
  const AgentsPage({super.key});

  void _edit(BuildContext context, [String? id]) =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => AgentEditPage(agentId: id)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final agents = ref.watch(agentsProvider).value ?? const [];
    final models = ref.watch(modelsProvider).value ?? const [];
    return SettingsScaffold(
      title: tr('助手'),
      actions: [
        AppIconButton(icon: AppIcons.add, onPressed: () => _edit(context)),
      ],
      children: [
        if (agents.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 32),
            child: Column(
              children: [
                MiuixText(
                  tr('助手 = 模型 + 系统提示词 + 参数\n例如「翻译官」「代码审查」，聊天时直接选用'),
                  textAlign: TextAlign.center,
                  color: colors.onSurfaceVariantSummary,
                ),
                const SizedBox(height: 24),
                PrimaryButton(
                  text: tr('新建助手'),
                  onPressed: () => _edit(context),
                ),
              ],
            ),
          )
        else
          SettingsGroup(
            children: [
              for (final a in agents)
                MiuixArrowPreference(
                  title: a.name,
                  summary: [
                    models
                            .where((m) => m.model.id == a.modelId)
                            .firstOrNull
                            ?.model
                            .displayName ??
                        tr('未设置模型'),
                    if (a.systemPrompt.trim().isNotEmpty)
                      a.systemPrompt
                          .trim()
                          .replaceAll('\n', ' ')
                          .characters
                          .take(24)
                          .toString(),
                  ].join(' · '),
                  onClick: () => _edit(context, a.id),
                ),
            ],
          ),
      ],
    );
  }
}

class AgentEditPage extends ConsumerStatefulWidget {
  const AgentEditPage({super.key, this.agentId});

  final String? agentId;

  @override
  ConsumerState<AgentEditPage> createState() => _AgentEditPageState();
}

class _AgentEditPageState extends ConsumerState<AgentEditPage> {
  final _name = TextEditingController();
  final _prompt = TextEditingController();
  final _temperature = TextEditingController();
  final _maxTokens = TextEditingController();
  final _snackbar = MiuixSnackbarHostState();
  String? _modelId;
  ReasoningEffort _reasoning = ReasoningEffort.auto;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.agentId;
    if (id == null) {
      setState(() => _loaded = true);
      return;
    }
    final a = await ref.read(agentRepositoryProvider).get(id);
    if (!mounted || a == null) return;
    final p = GenParams.fromJson(a.paramsJson);
    setState(() {
      _name.text = a.name;
      _prompt.text = a.systemPrompt;
      _modelId = a.modelId;
      _temperature.text = p.temperature?.toString() ?? '';
      _maxTokens.text = p.maxTokens?.toString() ?? '';
      _reasoning = p.reasoning;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _prompt, _temperature, _maxTokens]) {
      c.dispose();
    }
    _snackbar.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final temp = _temperature.text.trim().isEmpty
        ? null
        : double.tryParse(_temperature.text.trim());
    final max = _maxTokens.text.trim().isEmpty
        ? null
        : int.tryParse(_maxTokens.text.trim());
    if (_temperature.text.trim().isNotEmpty &&
        (temp == null || temp < 0 || temp > 2)) {
      _snackbar.showSnackbar(tr('温度应为 0~2 之间的数字'));
      return;
    }
    if (_maxTokens.text.trim().isNotEmpty && (max == null || max <= 0)) {
      _snackbar.showSnackbar(tr('最大输出应为正整数'));
      return;
    }
    await ref
        .read(agentRepositoryProvider)
        .save(
          id: widget.agentId,
          name: _name.text,
          modelId: _modelId,
          systemPrompt: _prompt.text,
          params: GenParams(
            temperature: temp,
            maxTokens: max,
            reasoning: _reasoning,
          ),
        );
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _delete() async {
    final ok = await showConfirm(
      context,
      title: tr('删除助手'),
      message: tr('已有对话中使用该助手的回答会保留。'),
      confirmText: tr('删除'),
      destructive: true,
    );
    if (!ok) return;
    await ref.read(agentRepositoryProvider).delete(widget.agentId!);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final models = (ref.watch(modelsProvider).value ?? const [])
        .where((m) => m.routes.isNotEmpty)
        .toList();
    final modelIdx = models.indexWhere((m) => m.model.id == _modelId);

    return SettingsScaffold(
      title: widget.agentId == null ? tr('新建助手') : tr('编辑助手'),
      snackbar: _snackbar,
      bottomBar: PrimaryButton(
        text: tr('保存'),
        enabled: _loaded,
        onPressed: _save,
      ),
      children: [
        SettingsGroup(
          title: tr('基本'),
          children: [
            SettingsField(
              controller: _name,
              label: tr('名称'),
              autocorrect: true,
            ),
            if (models.isEmpty)
              MiuixBasicComponent(
                title: tr('模型'),
                summary: tr('还没有可用模型，请先添加渠道'),
              )
            else
              MiuixOverlayDropdownPreference(
                title: tr('模型'),
                items: [for (final m in models) m.model.displayName],
                selectedIndex: modelIdx < 0 ? 0 : modelIdx,
                summary: modelIdx < 0 ? tr('请选择') : null,
                onSelectedIndexChange: (i) =>
                    setState(() => _modelId = models[i].model.id),
              ),
          ],
        ),
        SettingsGroup(
          title: tr('系统提示词'),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: AppTextField(
                controller: _prompt,
                label: tr('例如：你是一名专业的中英翻译……'),
                useLabelAsPlaceholder: true,
                minLines: 4,
                maxLines: 14,
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: tr('参数（留空使用模型默认值）'),
          children: [
            SettingsField(
              controller: _temperature,
              label: tr('温度 (0~2)'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            SettingsField(
              controller: _maxTokens,
              label: tr('最大输出 tokens'),
              keyboardType: TextInputType.number,
            ),
            MiuixOverlayDropdownPreference(
              title: tr('推理强度'),
              summary: tr('仅对带「推理」标签的模型生效'),
              items: [for (final r in ReasoningEffort.values) r.label],
              selectedIndex: ReasoningEffort.values.indexOf(_reasoning),
              onSelectedIndexChange: (i) =>
                  setState(() => _reasoning = ReasoningEffort.values[i]),
            ),
          ],
        ),
        if (widget.agentId != null)
          SettingsGroup(
            children: [
              MiuixBasicComponent(
                title: tr('删除助手'),
                titleColor: MiuixBasicComponentColors(
                  color: colors.error,
                  disabledColor: colors.disabledOnSurface,
                ),
                onClick: _delete,
              ),
            ],
          ),
      ],
    );
  }
}
