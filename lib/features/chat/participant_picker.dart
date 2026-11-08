import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/chat/conversation_mode.dart';
import '../../core/chat/participant.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/motion.dart';
import '../../ui/settings_widgets.dart';
import '../channels/channels_page.dart';

/// 选择会话的模式与模型 / 助手。
/// - 单模型：点一下立即生效；
/// - 多 Agent 并问：多选，同一问题同时发给多个；
/// - 接力分析：多选并排序，按顺序依次分析。
class ParticipantPickerPage extends ConsumerStatefulWidget {
  const ParticipantPickerPage({
    super.key,
    required this.conversationId,
    this.initialMode,
  });

  final String conversationId;

  /// 从新会话的「选择对话方式」进入时，预先选好的模式。
  final ConversationMode? initialMode;

  @override
  ConsumerState<ParticipantPickerPage> createState() =>
      _ParticipantPickerPageState();
}

class _ParticipantPickerPageState extends ConsumerState<ParticipantPickerPage> {
  final _snackbar = MiuixSnackbarHostState();
  List<Participant>? _selected;
  ConversationMode _mode = ConversationMode.single;

  @override
  void dispose() {
    _snackbar.dispose();
    super.dispose();
  }

  Future<void> _apply(List<Participant> list) async {
    if (_mode.isGroup && list.length < 2) {
      _snackbar.showSnackbar('${_mode.label}至少需要选择 2 个');
      return;
    }
    final mode = list.length > 1 ? _mode : ConversationMode.single;
    await ref
        .read(chatServiceProvider)
        .setParticipants(widget.conversationId, list, mode: mode);
    rememberParticipants(ref, list, mode);
    if (mounted) Navigator.of(context).maybePop();
  }

  void _tap(Participant p) {
    if (!_mode.isGroup) {
      _apply([p]);
      return;
    }
    setState(() {
      final sel = _selected!;
      if (!sel.remove(p)) sel.add(p);
    });
  }

  void _move(int from, int delta) {
    final sel = _selected!;
    final to = from + delta;
    if (to < 0 || to >= sel.length) return;
    setState(() => sel.insert(to, sel.removeAt(from)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final conv = ref.watch(conversationProvider(widget.conversationId));
    final models = (ref.watch(modelsProvider).value ?? const [])
        .where((m) => m.model.enabled && m.routes.isNotEmpty)
        .toList();
    final agents = ref.watch(agentsProvider).value ?? const [];
    if (_selected == null && conv != null) {
      _selected = Participant.decodeList(conv.participantsJson);
      _mode =
          widget.initialMode ??
          ConversationMode.fromId(conv.mode, participants: _selected!.length);
      if (!_mode.isGroup && _selected!.length > 1) {
        _selected = [_selected!.first];
      }
    }
    final selected = _selected ?? [];
    final chain = _mode == ConversationMode.chain;
    String label(Participant p) => participantLabel(p, models, agents);

    Widget item(
      Participant p,
      String title,
      String? summary, {
      bool enabled = true,
    }) {
      final index = selected.indexOf(p);
      return MiuixBasicComponent(
        title: title,
        summary: summary,
        enabled: enabled,
        endActions: [
          if (chain && index >= 0)
            _OrderBadge(index + 1)
          else if (_mode.isGroup)
            MiuixCheckbox(
              value: index >= 0,
              enabled: enabled,
              onChanged: (_) => _tap(p),
            )
          else if (index >= 0)
            MiuixText('当前', fontSize: 13, color: colors.primary),
        ],
        onClick: enabled ? () => _tap(p) : null,
      );
    }

    return SettingsScaffold(
      title: '选择模型',
      snackbar: _snackbar,
      bottomBar: _mode.isGroup
          ? PrimaryButton(
              text: chain
                  ? '确定（${selected.length} 步）'
                  : '确定（已选 ${selected.length} 个）',
              enabled: selected.length >= 2,
              onPressed: () => _apply(List.of(selected)),
            )
          : null,
      children: [
        SettingsGroup(
          children: [
            MiuixOverlayDropdownPreference(
              title: '模式',
              summary: _mode.description,
              items: [for (final m in ConversationMode.values) m.label],
              selectedIndex: ConversationMode.values.indexOf(_mode),
              onSelectedIndexChange: (i) => setState(() {
                _mode = ConversationMode.values[i];
                if (!_mode.isGroup && selected.length > 1) {
                  _selected = [selected.first];
                }
              }),
            ),
          ],
        ),
        // 执行顺序区出现 / 增删步骤时平滑伸缩，下方列表不会跳动。
        AnimatedSize(
          duration: Motion.medium,
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: !(chain && selected.isNotEmpty)
              ? const SizedBox(width: double.infinity)
              : SettingsGroup(
                  title: '执行顺序（第 1 步收到原始问题，之后每步收到原始问题 + 上一步结果）',
                  children: [
                    for (final (i, p) in selected.indexed)
                      MiuixBasicComponent(
                        title: label(p),
                        summary: i == 0
                            ? '分析原始问题'
                            : i == selected.length - 1
                            ? '给出最终结论'
                            : '在上一步基础上继续分析',
                        startAction: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: _OrderBadge(i + 1),
                        ),
                        endActions: [
                          _ArrowButton(
                            up: true,
                            enabled: i > 0,
                            onTap: () => _move(i, -1),
                          ),
                          _ArrowButton(
                            up: false,
                            enabled: i < selected.length - 1,
                            onTap: () => _move(i, 1),
                          ),
                        ],
                      ),
                  ],
                ),
        ),
        if (models.isEmpty)
          SettingsGroup(
            children: [
              MiuixArrowPreference(
                title: '还没有可用的模型',
                summary: '先添加渠道并拉取模型',
                onClick: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const ChannelsPage())),
              ),
            ],
          ),
        if (agents.isNotEmpty)
          SettingsGroup(
            title: '助手',
            children: [
              for (final a in agents)
                item(
                  Participant(modelId: a.modelId ?? '', agentId: a.id),
                  a.name,
                  a.modelId == null
                      ? '未设置模型'
                      : models
                                .where((m) => m.model.id == a.modelId)
                                .firstOrNull
                                ?.model
                                .displayName ??
                            '模型不可用',
                  enabled:
                      a.modelId != null &&
                      models.any((m) => m.model.id == a.modelId),
                ),
            ],
          ),
        if (models.isNotEmpty)
          SettingsGroup(
            title: '模型',
            children: [
              for (final m in models)
                item(
                  Participant(modelId: m.model.id),
                  m.model.displayName,
                  m.routes.length > 1
                      ? '${m.routes.length} 个渠道轮询'
                      : m.routes.first.channel.name,
                ),
            ],
          ),
        if (chain)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 0),
            child: MiuixText(
              '提示：给每一步配一个带系统提示词的「助手」（如「初稿」「审校」「总结」），接力效果更好。',
              fontSize: 12,
              color: colors.onSurfaceVariantSummary,
            ),
          ),
      ],
    );
  }
}

/// 圆形序号。
class _OrderBadge extends StatelessWidget {
  const _OrderBadge(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.primary, shape: BoxShape.circle),
      child: MiuixText(
        '$n',
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: colors.onPrimary,
      ),
    );
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.up,
    required this.enabled,
    required this.onTap,
  });

  final bool up;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Tap(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: RotatedBox(
          quarterTurns: up ? 3 : 1,
          child: MiuixIcon(
            vector: AppIcons.chevron,
            size: 16,
            tint: enabled
                ? colors.onSurfaceVariantActions
                : colors.disabledOnSurface,
          ),
        ),
      ),
    );
  }
}
