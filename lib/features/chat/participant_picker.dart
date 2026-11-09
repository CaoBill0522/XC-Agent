import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/chat/conversation_mode.dart';
import '../../core/chat/conversation_options.dart';
import '../../core/chat/participant.dart';
import '../../core/api/api_error.dart';
import '../../data/chat_service.dart';
import '../../data/usage_service.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/motion.dart';
import '../../ui/settings_widgets.dart';
import '../channels/channels_page.dart';
import '../../l10n/tr.dart';

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
  ConversationOptions _options = const ConversationOptions();

  @override
  void dispose() {
    _snackbar.dispose();
    super.dispose();
  }

  /// 已经在保存：保存完成、页面开始返回之前按钮还能再被点到，
  /// 重复执行会多返回一层，把聊天页也关掉（模拟器上复现过）。
  bool _applying = false;

  Future<void> _apply(List<Participant> list) async {
    if (_applying) return;
    if (_mode.isGroup && list.length < 2) {
      _snackbar.showSnackbar(trArgs('{0}至少需要选择 2 个', [_mode.label]));
      return;
    }
    _applying = true;
    final mode = list.length > 1 ? _mode : ConversationMode.single;
    await ref
        .read(chatServiceProvider)
        .setParticipants(
          widget.conversationId,
          list,
          mode: mode,
          options: _options,
        );
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
      _options = ConversationOptions.decode(conv.optionsJson);
      if (!_mode.isGroup && _selected!.length > 1) {
        _selected = [_selected!.first];
      }
    }
    final selected = _selected ?? [];
    // 接力和辩论都按顺序进行，需要排序。
    final chain = _mode.isSequential;
    final debate = _mode == ConversationMode.debate;
    // 裁判 / 总结者的候选：可用的助手和模型。
    final judgeCandidates = [
      for (final a in agents)
        if (a.modelId != null && models.any((m) => m.model.id == a.modelId))
          Participant(modelId: a.modelId!, agentId: a.id),
      for (final m in models) Participant(modelId: m.model.id),
    ];
    final judgeIndex = _options.judge == null
        ? 0
        : judgeCandidates.indexOf(_options.judge!) + 1;
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
            MiuixText(tr('当前'), fontSize: 13, color: colors.primary),
        ],
        onClick: enabled ? () => _tap(p) : null,
      );
    }

    return SettingsScaffold(
      title: tr('对话设置'),
      snackbar: _snackbar,
      bottomBar: _mode.isGroup
          ? PrimaryButton(
              text: chain && !debate
                  ? trArgs('确定（{0} 步）', [selected.length])
                  : trArgs('确定（已选 {0} 个）', [selected.length]),
              enabled: selected.length >= 2,
              onPressed: () => _apply(List.of(selected)),
            )
          : null,
      children: [
        SettingsGroup(
          children: [
            MiuixOverlayDropdownPreference(
              title: tr('模式'),
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
        // 裁判 / 辩论：裁判或总结者、辩论轮数。
        AnimatedSize(
          duration: Motion.medium,
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: !_mode.hasJudge
              ? const SizedBox(width: double.infinity)
              : SettingsGroup(
                  children: [
                    MiuixOverlayDropdownPreference(
                      title: debate ? tr('总结者') : tr('裁判'),
                      summary: debate
                          ? tr('辩论结束后梳理各方观点并给出结论')
                          : tr('对比各个回答、打分，并给出综合答案'),
                      items: [
                        debate ? tr('第一位辩手') : tr('第一个回答者'),
                        for (final p in judgeCandidates) label(p),
                      ],
                      selectedIndex: judgeIndex < 0 ? 0 : judgeIndex,
                      onSelectedIndexChange: (i) => setState(
                        () => _options = _options.copyWith(
                          judge: () => i == 0 ? null : judgeCandidates[i - 1],
                        ),
                      ),
                    ),
                    if (debate)
                      MiuixOverlayDropdownPreference(
                        title: tr('辩论轮数'),
                        summary: tr('每轮每位辩手各发言一次'),
                        items: [
                          for (final r in ConversationOptions.roundChoices)
                            trArgs('{0} 轮', [r]),
                        ],
                        selectedIndex: ConversationOptions.roundChoices
                            .indexOf(_options.rounds)
                            .clamp(0, 2),
                        onSelectedIndexChange: (i) => setState(
                          () => _options = _options.copyWith(
                            rounds: ConversationOptions.roundChoices[i],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        // 执行顺序区出现 / 增删步骤时平滑伸缩，下方列表不会跳动。
        AnimatedSize(
          duration: Motion.medium,
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: !(chain && selected.isNotEmpty)
              ? const SizedBox(width: double.infinity)
              : SettingsGroup(
                  title: debate
                      ? tr('发言顺序（每轮按这个顺序发言）')
                      : tr('执行顺序（第 1 步收到原始问题，之后每步收到原始问题 + 上一步结果）'),
                  children: [
                    for (final (i, p) in selected.indexed)
                      MiuixBasicComponent(
                        title: label(p),
                        summary: debate
                            ? (i == 0
                                  ? tr('先发言')
                                  : trArgs('第 {0} 个发言', [i + 1]))
                            : i == 0
                            ? tr('分析原始问题')
                            : i == selected.length - 1
                            ? tr('给出最终结论')
                            : tr('在上一步基础上继续分析'),
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
                title: tr('还没有可用的模型'),
                summary: tr('先添加渠道并拉取模型'),
                onClick: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const ChannelsPage())),
              ),
            ],
          ),
        if (agents.isNotEmpty)
          SettingsGroup(
            title: tr('助手'),
            children: [
              for (final a in agents)
                item(
                  Participant(modelId: a.modelId ?? '', agentId: a.id),
                  a.name,
                  a.modelId == null
                      ? tr('未设置模型')
                      : models
                                .where((m) => m.model.id == a.modelId)
                                .firstOrNull
                                ?.model
                                .displayName ??
                            tr('模型不可用'),
                  enabled:
                      a.modelId != null &&
                      models.any((m) => m.model.id == a.modelId),
                ),
            ],
          ),
        if (models.isNotEmpty)
          SettingsGroup(
            title: tr('模型'),
            children: [
              for (final m in models)
                item(
                  Participant(modelId: m.model.id),
                  m.model.displayName,
                  m.routes.length > 1
                      ? trArgs('{0} 个渠道轮询', [m.routes.length])
                      : m.routes.first.channel.name,
                ),
            ],
          ),
        if (chain && !debate)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 0),
            child: MiuixText(
              tr('提示：给每一步配一个带系统提示词的「助手」（如「初稿」「审校」「总结」），接力效果更好。'),
              fontSize: 12,
              color: colors.onSurfaceVariantSummary,
            ),
          ),
        if (conv != null)
          _ContextSettings(
            conversationId: widget.conversationId,
            options: _options,
            onChanged: (o) {
              setState(() => _options = o);
              ref
                  .read(chatServiceProvider)
                  .setOptions(widget.conversationId, o);
            },
            onToast: _snackbar.showSnackbar,
          ),
      ],
    );
  }
}

/// 上下文设置：携带多少轮历史、过长时自动压缩、立即压缩 / 清除摘要。
/// 改动立即保存（不需要点「确定」）。
class _ContextSettings extends ConsumerStatefulWidget {
  const _ContextSettings({
    required this.conversationId,
    required this.options,
    required this.onChanged,
    required this.onToast,
  });

  final String conversationId;
  final ConversationOptions options;
  final ValueChanged<ConversationOptions> onChanged;
  final ValueChanged<String> onToast;

  @override
  ConsumerState<_ContextSettings> createState() => _ContextSettingsState();
}

class _ContextSettingsState extends ConsumerState<_ContextSettings> {
  Future<int>? _tokens;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _estimate();
  }

  @override
  void didUpdateWidget(_ContextSettings old) {
    super.didUpdateWidget(old);
    if (old.options.encode() != widget.options.encode()) _estimate();
  }

  void _estimate() => _tokens = ref
      .read(chatServiceProvider)
      .contextTokens(widget.conversationId);

  Future<void> _compress() async {
    setState(() => _busy = true);
    try {
      await ref.read(chatServiceProvider).compress(widget.conversationId);
      final conv = await ref
          .read(chatServiceProvider)
          .conversation(widget.conversationId);
      widget.onChanged(ConversationOptions.decode(conv?.optionsJson));
      widget.onToast(tr('已把早期对话压缩成摘要'));
    } on ApiException catch (e) {
      widget.onToast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.options;
    final choices = ConversationOptions.contextChoices;
    final memory = o.memory;
    return SettingsGroup(
      title: tr('上下文'),
      children: [
        FutureBuilder<int>(
          future: _tokens,
          builder: (context, snap) => MiuixBasicComponent(
            title: trArgs('下次请求约 {0} tokens', [
              snap.hasData ? formatTokens(snap.data!) : '…',
            ]),
            summary: tr('按字数粗略估算，不含图片和 PDF'),
          ),
        ),
        MiuixOverlayDropdownPreference(
          title: tr('携带历史'),
          summary: tr('每次只把最近几轮对话发给模型，省钱也避免超出上限'),
          items: [
            for (final n in choices)
              n == null ? tr('全部') : trArgs('最近 {0} 轮', [n]),
          ],
          selectedIndex: choices
              .indexOf(o.contextTurns)
              .clamp(0, choices.length - 1),
          onSelectedIndexChange: (i) =>
              widget.onChanged(o.copyWith(contextTurns: () => choices[i])),
        ),
        MiuixSwitchPreference(
          title: tr('过长时自动压缩'),
          summary: trArgs('超过约 {0} tokens 时，先把早期对话总结成摘要再回答', [
            formatTokens(ChatService.autoCompressTokens),
          ]),
          value: o.autoCompress,
          onChanged: (v) => widget.onChanged(o.copyWith(autoCompress: v)),
        ),
        MiuixArrowPreference(
          title: _busy ? tr('正在压缩…') : tr('立即压缩早期对话'),
          summary: memory == null
              ? trArgs('保留最近 {0} 轮原文，之前的内容总结成摘要', [ChatService.keepRecentTurns])
              : trArgs('已有摘要（约 {0} tokens），再次压缩会合并进去', [
                  formatTokens(estimateTokens(memory.summary)),
                ]),
          enabled: !_busy,
          onClick: _busy ? null : _compress,
        ),
        if (memory != null)
          MiuixArrowPreference(
            title: tr('清除摘要'),
            summary: tr('恢复按原文发送全部历史'),
            onClick: () async {
              await ref
                  .read(chatServiceProvider)
                  .clearCompression(widget.conversationId);
              widget.onChanged(o.copyWith(memory: () => null));
            },
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
