import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/adapters/adapter.dart';
import '../../core/api/api_error.dart';
import '../../core/api/protocol.dart';
import '../../core/chat/conversation_mode.dart';
import '../../core/chat/participant.dart';
import '../../data/chat_service.dart';
import '../../data/image_store.dart';
import '../../data/providers.dart';
import '../../ui/animated_keyed_list.dart';
import '../../ui/app_icons.dart';
import '../../ui/layout.dart';
import '../../ui/measure_size.dart';
import '../../ui/motion.dart';
import '../channels/channels_page.dart';
import 'input_bar.dart';
import 'message_views.dart';
import 'participant_picker.dart';
import '../../ui/top_bar_text.dart';
import '../../ui/scroll_anchor.dart';
import '../search/search_page.dart';
import 'export.dart';
import 'follow_up.dart';

/// 聊天页。[embedded] 为 true 时嵌在桌面双栏右侧（不显示返回按钮）。
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    super.key,
    required this.conversationId,
    this.embedded = false,
  });

  final String conversationId;
  final bool embedded;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = InputBarController();
  final _snackbar = MiuixSnackbarHostState();
  final _inputHeight = ValueNotifier<double>(0);
  bool _dragging = false;
  // dispose 时 ref 已不可用，提前取好。
  late final ChatService _service;
  final _anchor = ScrollAnchor();
  final _list = ScrollController();

  /// 从搜索结果打开时要定位并高亮的消息。
  String? _focusId;
  final _focusKey = GlobalKey();
  bool _flash = false;
  bool _focusStarted = false;

  /// 顶栏标题两侧的边距：按钮区（16 边距 + 每个 40 宽）再加 8 间隙。
  static double _titleInset({required bool hasBack, required int actions}) {
    const edge = 16.0, button = 40.0, gap = 8.0;
    final left = hasBack ? edge + button : 0.0;
    final right = edge + button * actions;
    return (left > right ? left : right) + gap;
  }

  static bool _contains(ChatItem item, String? id) =>
      id != null &&
      switch (item) {
        SingleItem(:final message) => message.id == id,
        AnswerGroupItem(:final answers) => answers.any((m) => m.id == id),
      };
  final _clearSelections = ValueNotifier<int>(0);

  /// 由「新对话追问」打开：离开时若一条消息都没发，就删掉这个对话。
  bool _isFollowUp = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(chatServiceProvider);
    _focusId = ref.read(pendingFocusProvider).take(widget.conversationId);
    final draft = ref.read(pendingDraftsProvider).take(widget.conversationId);
    if (draft != null) {
      _isFollowUp = true;
      _input.quote = draft.quote;
      _input.setSummary(draft.summary);
    }
  }

  void _quoteHere(String selection) => _input.setQuote(selection);

  /// 把 [_focusId] 所在的消息滚到可视区并闪一下。列表是懒加载的，目标还没
  /// 构建时先往更早的方向翻页，直到它出现。
  Future<void> _scrollToFocus() async {
    await WidgetsBinding.instance.endOfFrame;
    for (var i = 0; i < 80 && mounted; i++) {
      final ctx = _focusKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: Motion.medium,
          curve: Motion.curve,
        );
        if (!mounted) return;
        setState(() => _flash = true);
        await Future<void>.delayed(const Duration(milliseconds: 1400));
        if (mounted) setState(() => _flash = false);
        return;
      }
      if (!_list.hasClients) {
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
      final pos = _list.position;
      if (pos.pixels >= pos.maxScrollExtent) {
        // 已到最早的消息仍没找到（可能被删了）。
        if (i > 3) return;
      } else {
        pos.jumpTo(
          (pos.pixels + pos.viewportDimension * 0.8).clamp(
            pos.minScrollExtent,
            pos.maxScrollExtent,
          ),
        );
      }
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> _askInNew(String sourceMsgId, String selection) async {
    try {
      final id = await _service.createFollowUp(sourceMsgId, selection);
      ref
          .read(pendingDraftsProvider)
          .put(
            id,
            PendingDraft(
              quote: selection,
              summary: SummaryJob.start(_service, sourceMsgId, selection),
            ),
          );
      await _openConversation(id);
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  /// 打开另一个对话：宽屏切换右栏；窄屏压在当前对话之上，返回即回到原对话。
  Future<void> _openConversation(String id) async {
    if (!mounted) return;
    if (widget.embedded) {
      ref.read(selectedConversationProvider.notifier).select(id);
    } else {
      await Navigator.of(context).push(appRoute(ChatPage(conversationId: id)));
    }
  }

  Future<void> _branchFrom(String msgId) async {
    try {
      final id = await _service.branchFrom(msgId);
      await _openConversation(id);
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  @override
  void dispose() {
    // 新建后什么都没做就离开：删掉这个空会话。聊天页在返回动画结束后才销毁，
    // 列表里随后播放该项收起消失的动画。
    _service
        .discardIfEmpty(widget.conversationId, force: _isFollowUp)
        .catchError((Object _) => false);
    _input.dispose();
    _list.dispose();
    _clearSelections.dispose();
    _snackbar.dispose();
    _inputHeight.dispose();
    super.dispose();
  }

  void _toast(String msg) => _snackbar.showSnackbar(msg);

  /// 列表项的稳定 key。助手回答统一用 groupId：多 Agent / 接力的第一条回答
  /// 先单独出现、随后才和同组回答合并成一组，key 不变才不会闪一下。
  static Object _itemKey(ChatItem item) => switch (item) {
    SingleItem(:final message) =>
      message.role == 'assistant'
          ? (message.groupId ?? message.id)
          : message.id,
    AnswerGroupItem(:final groupId) => groupId,
  };

  void _openPicker([ConversationMode? mode]) => Navigator.of(context).push(
    appRoute(
      ParticipantPickerPage(
        conversationId: widget.conversationId,
        initialMode: mode,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final conv = ref.watch(conversationProvider(widget.conversationId));
    final messagesAsync = ref.watch(messagesProvider(widget.conversationId));
    final messages = messagesAsync.value ?? const [];
    final models = ref.watch(modelsProvider).value ?? const [];
    final agents = ref.watch(agentsProvider).value ?? const [];
    final participants = conv == null
        ? const <Participant>[]
        : Participant.decodeList(conv.participantsJson);

    final mode = ConversationMode.fromId(
      conv?.mode,
      participants: participants.length,
    );
    final names = participants.map((p) => participantLabel(p, models, agents));
    final subtitle = participants.isEmpty
        ? '未选择对话方式'
        : mode == ConversationMode.chain
        ? '接力：${names.join(' → ')}'
        : names.join('、');
    final generating = messages.any((m) => MsgStatus.isActive(m.status));
    final webSupported = participants.any((p) {
      final m = models.where((m) => m.model.id == p.modelId).firstOrNull;
      return m != null &&
          m.routes.any(
            (r) => supportsWebSearch(
              protocol: ApiProtocol.fromId(r.channel.protocol),
              presetId: r.channel.presetId,
              model: r.route.upstreamModel,
              baseUrl: r.channel.baseUrl,
            ),
          );
    });
    final items = ChatItem.group(messages);
    if (_focusId != null && messagesAsync.hasValue && !_focusStarted) {
      _focusStarted = true;
      _scrollToFocus();
    }

    final body = Column(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.medium,
            switchInCurve: Motion.curve,
            child: !messagesAsync.hasValue
                // 数据还没读出来时不要闪一下「空对话」提示。
                ? const SizedBox.expand(key: ValueKey('loading'))
                : messages.isEmpty
                ? _EmptyChat(
                    key: const ValueKey('empty'),
                    hasModels: models.isNotEmpty,
                    hasParticipants: participants.isNotEmpty,
                    last: participants.isEmpty
                        ? lastSetup(ref, models, agents)
                        : null,
                    lastLabel: (ps) =>
                        ps.map((p) => participantLabel(p, models, agents)),
                    onPick: _openPicker,
                    onReuse: (setup) => _service.setParticipants(
                      widget.conversationId,
                      setup.participants,
                      mode: setup.mode,
                    ),
                  )
                : LayoutBuilder(
                    key: const ValueKey('list'),
                    builder: (context, box) => ScrollAnchorScope(
                      anchor: _anchor,
                      child: AnimatedKeyedList<ChatItem>(
                        reverse: true,
                        // 接力步骤展开 / 收起时顶部不动、只往下伸缩。
                        physics: AnchoredScrollPhysics(anchor: _anchor),
                        controller: _list,
                        // reverse 列表的第 0 项在最底部（最新）。
                        items: items.reversed.toList(),
                        keyOf: _itemKey,
                        padding: EdgeInsets.symmetric(
                          horizontal: chatGutter(context, box.maxWidth),
                          vertical: 12,
                        ),
                        itemBuilder: (context, item) => _FocusFlash(
                          key: _contains(item, _focusId) ? _focusKey : null,
                          active: _flash && _contains(item, _focusId),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: switch (item) {
                              SingleItem(:final message)
                                  when message.role == 'user' =>
                                UserBubble(message: message),
                              SingleItem(:final message) => AssistantMessage(
                                message: message,
                              ),
                              AnswerGroupItem(:final answers, :final isChain)
                                  when isChain =>
                                ChainGroupView(steps: answers),
                              AnswerGroupItem(:final answers) =>
                                AnswerGroupView(answers: answers),
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        MeasureSize(
          onChange: (s) => _inputHeight.value = s.height,
          child: ChatInputBar(
            conversationId: widget.conversationId,
            controller: _input,
            generating: generating,
            webSearchSupported: webSupported,
            hasParticipants: participants.isNotEmpty,
            onError: _toast,
          ),
        ),
      ],
    );

    return MiuixScaffold(
      // 提示浮在输入栏上方，不遮住输入框。
      snackbarHost: SnackbarAbove(
        bottomOccupied: _inputHeight,
        child: MiuixSnackbarHost(state: _snackbar),
      ),
      topBar: TopBarTextFix(
        child: MiuixSmallTopAppBar(
          title: conv?.title ?? '',
          // miuix 的小标题只留固定 26 的边距，不避让两侧按钮，长标题会压在
          // 返回 / 分享 / 设置按钮上。按较宽一侧的按钮宽度留出对称边距，标题仍居中。
          titlePadding: _titleInset(
            hasBack: !widget.embedded,
            actions: messages.isNotEmpty ? 2 : 1,
          ),
          // miuix 的 subtitle 不限制行数，长了会换行挤压内容；改为单行省略。
          bottomContent: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
            child: Center(
              child: MiuixText(
                subtitle,
                fontSize: 13,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                color: colors.onSurfaceVariantSummary,
              ),
            ),
          ),
          navigationIcon: widget.embedded
              ? null
              : AppIconButton(
                  icon: AppIcons.back,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
          actions: [
            if (messages.isNotEmpty)
              AppIconButton(
                icon: AppIcons.share,
                onPressed: () => showExportSheet(
                  context,
                  ref,
                  conversationId: widget.conversationId,
                  toast: _toast,
                ),
              ),
            AppIconButton(icon: AppIcons.tune, onPressed: _openPicker),
          ],
        ),
      ),
      content: (padding) => Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: EdgeInsets.only(top: padding.top),
          child: DropTarget(
            enable: isDesktopPlatform,
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (details) async {
              setState(() => _dragging = false);
              for (final f in details.files) {
                final bytes = await f.readAsBytes();
                if (sniffImageMime(bytes) != null) {
                  await _input.addImageBytes(bytes);
                } else if (_input.addFile(bytes, f.name) case final error?) {
                  _toast(error);
                }
              }
            },
            child: Stack(
              children: [
                ChatActions(
                  quoteHere: _quoteHere,
                  askInNew: _askInNew,
                  clearSelections: _clearSelections,
                  branchFrom: _branchFrom,
                  shareMessage: (id) => showExportSheet(
                    context,
                    ref,
                    conversationId: widget.conversationId,
                    onlyMessageId: id,
                    toast: _toast,
                  ),
                  child: body,
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _dragging ? 1 : 0,
                      duration: Motion.fast,
                      child: Container(
                        margin: const EdgeInsets.all(12),
                        decoration: ShapeDecoration(
                          color: colors.primary.withValues(alpha: 0.08),
                          shape: MiuixSquircleBorder(
                            cornerRadius: 20,
                            side: BorderSide(color: colors.primary, width: 1.5),
                          ),
                        ),
                        child: Center(
                          child: MiuixText('松开以添加图片', color: colors.primary),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

typedef _Setup = ({List<Participant> participants, ConversationMode mode});

/// 空对话：没有模型时引导添加渠道；新会话还没选对话方式时，列出三种模式让用户选
/// （外加「沿用上次」快捷项）；都设置好了就显示欢迎语。
class _EmptyChat extends StatelessWidget {
  const _EmptyChat({
    super.key,
    required this.hasModels,
    required this.hasParticipants,
    required this.last,
    required this.lastLabel,
    required this.onPick,
    required this.onReuse,
  });

  final bool hasModels;
  final bool hasParticipants;
  final _Setup? last;
  final Iterable<String> Function(List<Participant>) lastLabel;
  final void Function([ConversationMode? mode]) onPick;
  final ValueChanged<_Setup> onReuse;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final Widget child;
    final String state;
    if (!hasModels) {
      state = 'no-models';
      child = _Hint(
        text: '还没有可用的模型',
        action: '添加渠道',
        onTap: () => Navigator.of(context).push(appRoute(const ChannelsPage())),
      );
    } else if (hasParticipants) {
      state = 'ready';
      child = const _Hint(text: '有什么可以帮你？');
    } else {
      state = 'setup';
      final last = this.last;
      MiuixVectorIcon iconOf(ConversationMode m) => switch (m) {
        // 一个气泡 / 两个气泡 / 自上而下依次进行。
        ConversationMode.single => AppIcons.reply,
        ConversationMode.multi => AppIcons.replyAll,
        ConversationMode.chain => AppIcons.sort,
        ConversationMode.judge => AppIcons.notes,
        ConversationMode.debate => AppIcons.merge,
      };
      Widget icon(MiuixVectorIcon v) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: MiuixIcon(vector: v, size: 24, tint: colors.primary),
      );
      child = LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: chatGutter(context, box.maxWidth),
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight - 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MiuixText(
                      '这次想怎么对话？',
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    MiuixText(
                      '选好之后也可以随时点右上角修改',
                      fontSize: 13,
                      color: colors.onSurfaceVariantSummary,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    MiuixCard(
                      child: Column(
                        children: [
                          for (final m in ConversationMode.values)
                            MiuixArrowPreference(
                              title: m.label,
                              summary: m.description,
                              startAction: icon(iconOf(m)),
                              onClick: () => onPick(m),
                            ),
                        ],
                      ),
                    ),
                    if (last != null) ...[
                      const SizedBox(height: 12),
                      MiuixCard(
                        child: MiuixArrowPreference(
                          title: '沿用上次',
                          summary: last.mode == ConversationMode.single
                              ? lastLabel(last.participants).join('、')
                              : '${last.mode.label}：${lastLabel(last.participants).join(last.mode == ConversationMode.chain ? ' → ' : '、')}',
                          startAction: icon(AppIcons.refresh),
                          onClick: () => onReuse(last),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return FadeSwitch(
      switchKey: state,
      animateSize: false,
      alignment: Alignment.center,
      child: KeyedSubtree(key: ValueKey(state), child: child),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text, this.action, this.onTap});

  final String text;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiuixText(text, color: colors.onSurfaceVariantSummary, fontSize: 16),
          if (action != null) ...[
            const SizedBox(height: 16),
            MiuixButton(
              onPressed: onTap!,
              colors: MiuixButtonDefaults.buttonColorsPrimary(context),
              child: MiuixText(action!, color: colors.onPrimary),
            ),
          ],
        ],
      ),
    );
  }
}

/// 搜索定位到的消息：背景淡入淡出闪一下。
class _FocusFlash extends StatelessWidget {
  const _FocusFlash({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return AnimatedContainer(
      duration: Motion.medium,
      curve: Motion.curve,
      decoration: ShapeDecoration(
        color: colors.primary.withValues(alpha: active ? 0.10 : 0),
        shape: const MiuixSquircleBorder(cornerRadius: 16),
      ),
      child: child,
    );
  }
}
