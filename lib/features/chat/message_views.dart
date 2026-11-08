import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/chat/chat_types.dart';
import '../../core/chat/participant.dart';
import '../../data/chat_service.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/image_view.dart';
import '../../ui/layout.dart';
import '../../ui/motion.dart';
import 'markdown_view.dart';
import '../../ui/links.dart';
import '../../ui/scroll_anchor.dart';
import 'follow_up.dart';

/// 消息列表里的一项：单条消息，或多 Agent 同组回答。
sealed class ChatItem {
  const ChatItem();

  static List<ChatItem> group(List<Message> messages) {
    final items = <ChatItem>[];
    for (final m in messages) {
      final last = items.lastOrNull;
      if (m.role == 'assistant' && m.groupId != null) {
        if (last is AnswerGroupItem && last.groupId == m.groupId) {
          last.answers.add(m);
          continue;
        }
        if (last is SingleItem &&
            last.message.role == 'assistant' &&
            last.message.groupId == m.groupId) {
          items[items.length - 1] = AnswerGroupItem(m.groupId!, [
            last.message,
            m,
          ]);
          continue;
        }
      }
      items.add(SingleItem(m));
    }
    return items;
  }
}

class SingleItem extends ChatItem {
  const SingleItem(this.message);
  final Message message;
}

class AnswerGroupItem extends ChatItem {
  AnswerGroupItem(this.groupId, this.answers);
  final String groupId;
  final List<Message> answers;

  /// 接力分析的步骤（带步骤序号）。
  bool get isChain => answers.any((m) => m.stepIndex != null);
}

// ──────────────── 用户消息

class UserBubble extends ConsumerWidget {
  const UserBubble({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final parts = ContentPart.decodeList(message.partsJson);
    final maxWidth =
        MediaQuery.sizeOf(context).width * (isWideLayout(context) ? 0.55 : 0.8);

    Future<void> actions() => showActionSheet(
      context,
      actions: [
        SheetAction(
          '复制',
          () => Clipboard.setData(ClipboardData(text: parts.text)),
          icon: AppIcons.copy,
        ),
        SheetAction('编辑并重新发送', () async {
          final text = await showTextInput(
            context,
            title: '编辑消息',
            initial: parts.text,
            multiline: true,
          );
          if (text != null) {
            await ref.read(chatServiceProvider).editAndResend(message.id, text);
          }
        }, icon: AppIcons.edit),
        SheetAction(
          '删除',
          () => ref.read(chatServiceProvider).deleteMessage(message.id),
          icon: AppIcons.delete,
          destructive: true,
        ),
      ],
    );

    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: actions,
        onSecondaryTap: actions,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (parts.contextSummary case final ctx?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _ContextSummaryChip(text: ctx),
                ),
              if (parts.quote case final q?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: QuoteCard(text: q, maxLines: 4),
                ),
              if (parts.images.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: [
                      for (final img in parts.images)
                        LocalImage(img, size: 120),
                    ],
                  ),
                ),
              if (parts.text.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: ShapeDecoration(
                    color: colors.primary,
                    shape: const MiuixSquircleBorder(cornerRadius: 18),
                  ),
                  child: SelectableText(
                    parts.text,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.45,
                      color: colors.onPrimary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 用户消息上方的「前文总结」：默认一行，点开查看全文。
class _ContextSummaryChip extends StatefulWidget {
  const _ContextSummaryChip({required this.text});
  final String text;

  @override
  State<_ContextSummaryChip> createState() => _ContextSummaryChipState();
}

class _ContextSummaryChipState extends State<_ContextSummaryChip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Tap(
      sink: false,
      onTap: () => setState(() => _open = !_open),
      child: AnimatedSize(
        duration: Motion.medium,
        curve: Motion.curve,
        alignment: Alignment.topRight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: ShapeDecoration(
            color: colors.primary.withValues(alpha: 0.06),
            shape: const MiuixSquircleBorder(cornerRadius: 12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              MiuixText(
                _open ? '前文总结' : '前文总结 · 点击展开',
                fontSize: 12,
                color: colors.primary,
              ),
              if (_open) ...[
                const SizedBox(height: 4),
                SelectableText(
                  widget.text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────── 助手回答

class AssistantMessage extends ConsumerWidget {
  const AssistantMessage({
    super.key,
    required this.message,
    this.showHeader = true,
  });

  final Message message;
  final bool showHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final parts = ContentPart.decodeList(message.partsJson);
    final models = ref.watch(modelsProvider).value ?? const [];
    final agents = ref.watch(agentsProvider).value ?? const [];
    final label = message.modelId == null
        ? '助手'
        : participantLabel(
            Participant(modelId: message.modelId!, agentId: message.agentId),
            models,
            agents,
          );
    final channelName = models
        .expand((m) => m.routes)
        .where((r) => r.channel.id == message.channelId)
        .firstOrNull
        ?.channel
        .name;
    final active = MsgStatus.isActive(message.status);
    final service = ref.read(chatServiceProvider);

    // 流式输出时内容每 80ms 增长一截：用短时长的 AnimatedSize 把高度变化抹平，
    // 列表不会一跳一跳地往上顶。
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      // 不裁剪：操作图标的按压下沉效果会略超出边界。
      clipBehavior: Clip.none,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: MiuixText(
                [label, ?channelName].join(' · '),
                fontSize: 12,
                color: colors.onSurfaceVariantSummary,
              ),
            ),
          for (final n in parts.notices)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  MiuixIcon(
                    vector: AppIcons.info,
                    size: 14,
                    tint: colors.onSurfaceVariantSummary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: MiuixText(
                      n.text,
                      fontSize: 12,
                      color: colors.onSurfaceVariantSummary,
                    ),
                  ),
                ],
              ),
            ),
          if (parts.thinking.isNotEmpty)
            ThinkingBlock(
              text: parts.thinking,
              streaming: active && parts.text.isEmpty,
            ),
          if (parts.images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              // 图片宽度不超过可用宽度（多 Agent 并排、接力卡片里列宽较窄）。
              child: LayoutBuilder(
                builder: (context, box) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final img in parts.images)
                      LocalImage(
                        img,
                        size: box.maxWidth < 240 ? box.maxWidth : 240,
                        fit: BoxFit.contain,
                      ),
                  ],
                ),
              ),
            ),
          if (parts.text.isNotEmpty)
            SelectableAnswer(
              messageId: message.id,
              enabled:
                  message.status == MsgStatus.done ||
                  message.status == MsgStatus.stopped,
              child: MarkdownView(parts.text),
            ),
          if (active && parts.text.isEmpty && parts.thinking.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: MiuixInfiniteProgressIndicator(),
                  ),
                  const SizedBox(width: 8),
                  MiuixText(
                    message.status == MsgStatus.pending ? '正在连接…' : '生成中…',
                    fontSize: 13,
                    color: colors.onSurfaceVariantSummary,
                  ),
                ],
              ),
            ),
          if (parts.citations.isNotEmpty) CitationList(parts.citations),
          if (message.status == MsgStatus.error)
            ErrorCard(message: message.error ?? '未知错误'),
          if (message.status == MsgStatus.stopped)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: MiuixText(
                '已停止',
                fontSize: 12,
                color: colors.onSurfaceVariantSummary,
              ),
            ),
          PopSwitch(
            switchKey: active,
            child: Transform.translate(
              // _SmallAction 有 6 的内边距，左移让图标与正文左边缘对齐。
              offset: const Offset(-6, 0),
              child: !active
                  ? Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          _SmallAction(
                            icon: AppIcons.copy,
                            onTap: () => Clipboard.setData(
                              ClipboardData(text: parts.text),
                            ),
                          ),
                          _SmallAction(
                            icon: AppIcons.regenerate,
                            onTap: () => service.regenerate(message.id),
                          ),
                          _SmallAction(
                            icon: AppIcons.delete,
                            onTap: () => service.deleteMessage(message.id),
                          ),
                          if (message.usageJson case final u?) _UsageText(u),
                        ],
                      ),
                    )
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: _SmallAction(
                        icon: AppIcons.stop,
                        onTap: () => service.stop(message.id),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageText extends StatelessWidget {
  const _UsageText(this.json);
  final String json;

  @override
  Widget build(BuildContext context) {
    final m = RegExp(r'"output":(\d+)').firstMatch(json);
    if (m == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: MiuixText(
        '${m.group(1)} tokens',
        fontSize: 11,
        color: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
      ),
    );
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({required this.icon, required this.onTap});
  final MiuixVectorIcon icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: MiuixIcon(
          vector: icon,
          size: 18,
          tint: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
        ),
      ),
    );
  }
}

/// 可折叠的思考过程。
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({super.key, required this.text, required this.streaming});

  final String text;
  final bool streaming;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool? _expanded;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    // 思考中默认展开，输出正文后默认折叠；用户手动切换后以用户为准。
    final expanded = _expanded ?? widget.streaming;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: ShapeDecoration(
        color: colors.surfaceContainer,
        shape: const MiuixSquircleBorder(cornerRadius: 12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tap(
            sink: false,
            onTap: () => setState(() => _expanded = !expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  MiuixText(
                    widget.streaming ? '思考中…' : '思考过程',
                    fontSize: 13,
                    color: colors.onSurfaceVariantSummary,
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: expanded ? -0.25 : 0.25,
                    duration: Motion.medium,
                    curve: Motion.curve,
                    child: MiuixIcon(
                      vector: AppIcons.chevron,
                      size: 14,
                      tint: colors.onSurfaceVariantSummary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AppExpand(
            expanded: expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: SelectableText(
                widget.text.trim(),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: colors.onSurfaceVariantSummary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 联网搜索的来源：最多两行、每行 2~3 个（按宽度），放不下时最后一格显示「⋯」，
/// 点开底部面板查看全部来源。
class CitationList extends StatelessWidget {
  const CitationList(this.citations, {super.key});
  final List<CitationPart> citations;

  static const rows = 2;

  static String host(CitationPart c) {
    final h = Uri.tryParse(c.url)?.host ?? '';
    return h.startsWith('www.') ? h.substring(4) : (h.isEmpty ? c.url : h);
  }

  static String titleOf(CitationPart c) =>
      c.title?.trim().isNotEmpty == true ? c.title!.trim() : host(c);

  static void _open(String url) => openLink(url);

  Future<void> _showAll(BuildContext context) async {
    final picked = await showAppSheet<CitationPart>(
      context,
      title: '来源（${citations.length}）',
      builder: (ctx, close) {
        final colors = MiuixTheme.of(ctx).colors;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
          ),
          child: MiuixCard(
            colors: MiuixCardColors(
              color: colors.surfaceContainerHigh,
              contentColor: colors.onSurface,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final (i, c) in citations.indexed)
                  MiuixBasicComponent(
                    title: titleOf(c),
                    summary: host(c),
                    startAction: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _Index(i + 1),
                    ),
                    onClick: () => close(c),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) _open(picked.url);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: LayoutBuilder(
        builder: (context, box) {
          final cols = box.maxWidth >= 340 ? 3 : 2;
          final capacity = cols * rows;
          final overflow = citations.length > capacity;
          final shown = overflow
              ? citations.take(capacity - 1).toList()
              : citations;
          final cells = <Widget>[
            for (final (i, c) in shown.indexed)
              _Chip(index: i + 1, label: host(c), onTap: () => _open(c.url)),
            if (overflow) _Chip(label: '⋯', onTap: () => _showAll(context)),
          ];
          return Column(
            children: [
              for (var r = 0; r * cols < cells.length; r++)
                Padding(
                  padding: EdgeInsets.only(top: r == 0 ? 0 : 6),
                  child: Row(
                    children: [
                      for (var k = 0; k < cols; k++) ...[
                        if (k > 0) const SizedBox(width: 6),
                        Expanded(
                          child: r * cols + k < cells.length
                              ? cells[r * cols + k]
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({this.index, required this.label, required this.onTap});

  final int? index;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Tap(
      onTap: onTap,
      cornerRadius: 8,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: ShapeDecoration(
          // 淡主题色底：在卡片（白）和页面（灰）背景上都看得出边界。
          color: colors.primary.withValues(alpha: 0.08),
          shape: const MiuixSquircleBorder(cornerRadius: 8),
        ),
        child: Row(
          mainAxisAlignment: index == null
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            if (index != null) ...[
              MiuixText(
                '$index',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colors.onSurfaceVariantSummary,
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: MiuixText(
                label,
                fontSize: 12,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                color: index == null
                    ? colors.onSurfaceVariantSummary
                    : colors.primary,
                fontWeight: index == null ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 来源列表里的圆形序号。
class _Index extends StatelessWidget {
  const _Index(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: colors.surfaceContainer,
        shape: const CircleBorder(),
      ),
      child: MiuixText(
        '$n',
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: colors.onSurfaceVariantSummary,
      ),
    );
  }
}

class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: colors.error.withValues(alpha: 0.08),
        shape: const MiuixSquircleBorder(cornerRadius: 12),
      ),
      child: SelectableText(
        message,
        style: TextStyle(fontSize: 13, height: 1.45, color: colors.error),
      ),
    );
  }
}

// ──────────────── 多 Agent 同组回答

class AnswerGroupView extends ConsumerStatefulWidget {
  const AnswerGroupView({super.key, required this.answers});

  final List<Message> answers;

  @override
  ConsumerState<AnswerGroupView> createState() => _AnswerGroupViewState();
}

class _AnswerGroupViewState extends ConsumerState<AnswerGroupView> {
  int? _tab;

  /// 横滑切换：手指拖动的距离、最近一次切换的方向（决定滑入方向）。
  double _drag = 0;
  bool _dragging = false;
  int _dir = 1;

  /// [from] 是当前显示的回答（未手动切换过时是被采纳的那个，不一定是 0）。
  void _switchTo(int from, int to, int count) {
    if (to < 0 || to >= count || to == from) return;
    setState(() {
      _dir = to > from ? 1 : -1;
      _tab = to;
    });
  }

  void _adopt(Message m) {
    // 双击落在文字上时 iOS 会顺带选中一个词，撤销掉。
    ChatActions.maybeOf(context)?.clearSelections.value++;
    if (m.adopted || m.status != MsgStatus.done) return;
    HapticFeedback.lightImpact();
    ref.read(chatServiceProvider).adopt(m.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final models = ref.watch(modelsProvider).value ?? const [];
    final agents = ref.watch(agentsProvider).value ?? const [];
    final answers = widget.answers;
    String label(Message m) => participantLabel(
      Participant(modelId: m.modelId ?? '', agentId: m.agentId),
      models,
      agents,
    );

    Widget header(Message m) {
      final adopted = m.adopted;
      return Row(
        children: [
          Expanded(
            child: MiuixText(
              label(m),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 两种状态用同样的外边距，切换时不跳动；右边缘与卡片内容对齐。
          PopSwitch(
            switchKey: (adopted, m.status == MsgStatus.done),
            child: adopted
                ? Padding(
                    padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
                    child: _Badge('已采纳', color: colors.primary),
                  )
                : m.status == MsgStatus.done
                ? Tap(
                    onTap: () => ref.read(chatServiceProvider).adopt(m.id),
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 12,
                        top: 4,
                        bottom: 4,
                      ),
                      child: _Badge(
                        '采纳',
                        color: colors.onSurfaceVariantSummary,
                        outlined: true,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      );
    }

    final wide =
        MediaQuery.sizeOf(context).width >= kWideBreakpoint &&
        answers.length <= 3;
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, m) in answers.indexed) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: DoubleTapListener(
                onDoubleTap: () => _adopt(m),
                child: _AnswerCard(
                  highlighted: m.adopted,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header(m),
                      const SizedBox(height: 8),
                      AssistantMessage(message: m, showHeader: false),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    }

    final adoptedIdx = answers.indexWhere((m) => m.adopted);
    final tab = (_tab ?? (adoptedIdx < 0 ? 0 : adoptedIdx)).clamp(
      0,
      answers.length - 1,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (i, m) in answers.indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Tap(
                    onTap: () => _switchTo(tab, i, answers.length),
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      curve: Motion.curve,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: ShapeDecoration(
                        color: i == tab
                            ? colors.primary
                            : colors.surfaceContainer,
                        shape: const MiuixSquircleBorder(cornerRadius: 10),
                      ),
                      child: AnimatedDefaultTextStyle(
                        duration: Motion.fast,
                        style: TextStyle(
                          fontSize: 13,
                          color: i == tab ? colors.onPrimary : colors.onSurface,
                        ),
                        child: Text(
                          '${m.adopted ? '✓ ' : ''}${label(m)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 卡片上左右横滑切换回答（跟手拖动，两端有阻尼），双击采纳。
        DoubleTapListener(
          onDoubleTap: () => _adopt(answers[tab]),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => setState(() {
              _dragging = true;
              _drag = 0;
            }),
            onHorizontalDragUpdate: (d) {
              final atEdge =
                  (d.delta.dx > 0 && tab == 0) ||
                  (d.delta.dx < 0 && tab == answers.length - 1);
              setState(() => _drag += d.delta.dx * (atEdge ? 0.3 : 1));
            },
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              final to = _drag < -60 || v < -400
                  ? tab + 1
                  : _drag > 60 || v > 400
                  ? tab - 1
                  : tab;
              setState(() {
                _dragging = false;
                _drag = 0;
              });
              if (to != tab) {
                HapticFeedback.selectionClick();
                _switchTo(tab, to, answers.length);
              }
            },
            onHorizontalDragCancel: () => setState(() {
              _dragging = false;
              _drag = 0;
            }),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: _dragging ? _drag * 0.4 : 0),
              duration: _dragging ? Duration.zero : Motion.medium,
              curve: Motion.curve,
              builder: (context, dx, child) =>
                  Transform.translate(offset: Offset(dx, 0), child: child),
              child: _AnswerCard(
                highlighted: answers[tab].adopted,
                child: _SlideSwitch(
                  switchKey: answers[tab].id,
                  direction: _dir,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header(answers[tab]),
                      const SizedBox(height: 8),
                      AssistantMessage(
                        message: answers[tab],
                        showHeader: false,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: MiuixText(
            '左右滑动切换 · 双击采纳',
            fontSize: 11,
            color: colors.onSurfaceVariantSummary.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

/// 回答切换：新内容从滑动方向滑入，旧内容向反方向滑出并淡出；高度平滑过渡。
class _SlideSwitch extends StatelessWidget {
  const _SlideSwitch({
    required this.switchKey,
    required this.direction,
    required this.child,
  });

  final Object switchKey;
  final int direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final key = ValueKey(switchKey);
    return ClipRect(
      child: AnimatedSize(
        duration: Motion.medium,
        curve: Motion.curve,
        alignment: Alignment.topCenter,
        // 先退后进：旧内容 110ms 内滑出淡出，新内容等它基本消失后再滑入，
        // 两层文字不会叠在一起。
        child: AnimatedSwitcher(
          duration: Motion.medium,
          reverseDuration: const Duration(milliseconds: 110),
          switchInCurve: const Interval(0.3, 1, curve: Curves.easeOutCubic),
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            children: [
              for (final p in previous)
                Positioned(left: 0, right: 0, top: 0, child: p),
              ?current,
            ],
          ),
          // drive(Tween) 不向动画注册监听，闭包每次 build 重建也不会泄漏。
          transitionBuilder: (child, anim) {
            final incoming = child.key == key;
            final offset = Tween(
              begin: Offset(0.2 * (incoming ? direction : -direction), 0),
              end: Offset.zero,
            );
            return FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: anim.drive(offset),
                child: child,
              ),
            );
          },
          child: KeyedSubtree(key: key, child: child),
        ),
      ),
    );
  }
}

/// 双击检测：直接监听指针，不进入手势竞技场，
/// 不会让卡片里的按钮、标签等单击变慢。
class DoubleTapListener extends StatefulWidget {
  const DoubleTapListener({
    super.key,
    required this.onDoubleTap,
    required this.child,
  });

  final VoidCallback onDoubleTap;
  final Widget child;

  @override
  State<DoubleTapListener> createState() => _DoubleTapListenerState();
}

class _DoubleTapListenerState extends State<DoubleTapListener> {
  /// 指针下、本组件之内是否有可点击的控件（带单击手势的 GestureDetector /
  /// 按钮，或带点击识别器的文字片段如链接）。
  bool _onControl(PointerDownEvent e) {
    final self = context.findRenderObject();
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, e.position, e.viewId);
    for (final entry in result.path) {
      final t = entry.target;
      if (identical(t, self)) break;
      if (t is RenderSemanticsGestureHandler && t.onTap != null) return true;
      if (t is TextSpan && t.recognizer != null) return true;
    }
    return false;
  }

  static const _maxTap = Duration(milliseconds: 250);
  static const _maxGap = Duration(milliseconds: 300);

  Offset? _downPos;
  DateTime? _downAt;
  Offset? _lastTapPos;
  DateTime? _lastTapAt;
  int _pointers = 0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _pointers++;
        _downPos = e.position;
        // 落在按钮、链接等可点击控件上的点击不算（快速点两下展开 / 复制
        // 不能顺带采纳）。
        _downAt = _onControl(e) ? null : DateTime.now();
      },
      onPointerCancel: (_) {
        _pointers = 0;
        _downAt = null;
      },
      onPointerUp: (e) {
        _pointers = (_pointers - 1).clamp(0, 10);
        final down = _downAt;
        final now = DateTime.now();
        _downAt = null;
        // 不是一次干脆的点击（拖动、长按、多指）就重新计数。
        if (down == null ||
            _pointers > 0 ||
            now.difference(down) > _maxTap ||
            (e.position - _downPos!).distance > 18) {
          _lastTapAt = null;
          return;
        }
        final last = _lastTapAt;
        if (last != null &&
            now.difference(last) <= _maxGap &&
            (e.position - _lastTapPos!).distance < 40) {
          _lastTapAt = null;
          widget.onDoubleTap();
        } else {
          _lastTapAt = now;
          _lastTapPos = e.position;
        }
      },
      child: widget.child,
    );
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.child, required this.highlighted});
  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => HighlightCard(
    highlighted: highlighted,
    cornerRadius: 16,
    padding: const EdgeInsets.all(12),
    child: child,
  );
}

/// 带「被选中」高亮描边的卡片，描边颜色平滑过渡。
/// （MiuixSquircleBorder 没有实现 lerp，不能直接用 AnimatedContainer 过渡。）
class HighlightCard extends StatelessWidget {
  const HighlightCard({
    super.key,
    required this.highlighted,
    required this.child,
    this.cornerRadius = 14,
    this.padding = const EdgeInsets.all(12),
  });

  final bool highlighted;
  final Widget child;
  final double cornerRadius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: highlighted ? 1 : 0),
      duration: Motion.medium,
      curve: Motion.curve,
      child: child,
      builder: (context, t, child) => DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.surfaceContainer,
          shape: MiuixSquircleBorder(
            cornerRadius: cornerRadius,
            side: BorderSide(
              color: colors.primary.withValues(alpha: 0.6 * t),
              width: 1.2,
            ),
          ),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {required this.color, this.outlined = false});
  final String text;
  final Color color;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        color: outlined ? null : color.withValues(alpha: 0.12),
        shape: MiuixSquircleBorder(
          cornerRadius: 6,
          side: outlined
              ? BorderSide(color: color.withValues(alpha: 0.5))
              : BorderSide.none,
        ),
      ),
      child: MiuixText(text, fontSize: 11, color: color),
    );
  }
}

// ──────────────── 接力分析

class ChainGroupView extends ConsumerWidget {
  const ChainGroupView({super.key, required this.steps});

  final List<Message> steps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final sorted = [...steps]
      ..sort((a, b) => (a.stepIndex ?? 0).compareTo(b.stepIndex ?? 0));
    final models = ref.watch(modelsProvider).value ?? const [];
    final agents = ref.watch(agentsProvider).value ?? const [];
    String label(Message m) => participantLabel(
      Participant(modelId: m.modelId ?? '', agentId: m.agentId),
      models,
      agents,
    );
    final doneCount = sorted.where((m) => m.status == MsgStatus.done).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: MiuixText(
            '接力分析 · ${sorted.map(label).join(' → ')} · $doneCount/${sorted.length}',
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final (i, m) in sorted.indexed)
          _ChainStep(
            message: m,
            number: i + 1,
            label: label(m),
            isLast: i == sorted.length - 1,
          ),
      ],
    );
  }
}

class _ChainStep extends StatefulWidget {
  const _ChainStep({
    required this.message,
    required this.number,
    required this.label,
    required this.isLast,
  });

  final Message message;
  final int number;
  final String label;
  final bool isLast;

  @override
  State<_ChainStep> createState() => _ChainStepState();
}

class _ChainStepState extends State<_ChainStep> {
  bool? _expanded;
  bool _anchoring = false;
  Timer? _anchorTimer;

  @override
  void dispose() {
    _anchorTimer?.cancel();
    super.dispose();
  }

  static const _rail = 30.0;
  static const _badge = 24.0;
  static const _badgeTop = 12.0;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final m = widget.message;
    final active = MsgStatus.isActive(m.status);
    final hasContent = ContentPart.decodeList(m.partsJson).isNotEmpty;
    // 默认：正在生成、最终结论、出错的步骤展开；已完成的中间步骤折叠。
    final expanded =
        _expanded ??
        (widget.isLast || m.adopted || active || m.status == MsgStatus.error);
    final waiting = m.status == MsgStatus.pending && !hasContent;

    final (statusText, statusColor) = switch (m.status) {
      MsgStatus.pending when waiting => ('等待中', colors.onSurfaceVariantSummary),
      MsgStatus.pending || MsgStatus.streaming => ('分析中…', colors.primary),
      MsgStatus.error => ('失败', colors.error),
      MsgStatus.stopped => ('已停止', colors.onSurfaceVariantSummary),
      _ => (m.adopted ? '最终结论' : '完成', colors.primary),
    };

    final preview = ContentPart.decodeList(m.partsJson).text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final header = Tap(
      sink: false,
      onTap: waiting
          ? null
          : () {
              setState(() {
                _expanded = !expanded;
                _anchoring = true;
              });
              // 展开 / 收起动画期间顶部不动，只往下伸缩；结束后恢复正常
              //（之后流式输出等变化仍按聊天列表的习惯从底部增长）。
              _anchorTimer?.cancel();
              _anchorTimer = Timer(Motion.medium * 1.5, () {
                if (mounted) setState(() => _anchoring = false);
              });
            },
      child: Row(
        children: [
          Expanded(
            child: MiuixText(
              widget.label,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          PopSwitch(
            switchKey: statusText,
            child: MiuixText(statusText, fontSize: 12, color: statusColor),
          ),
          AnimatedOpacity(
            opacity: waiting ? 0 : 1,
            duration: Motion.fast,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: AnimatedRotation(
                turns: expanded ? -0.25 : 0.25,
                duration: Motion.medium,
                curve: Motion.curve,
                child: MiuixIcon(
                  vector: AppIcons.chevron,
                  size: 12,
                  tint: colors.onSurfaceVariantSummary,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // 折叠时显示的摘要；没有内容时显示错误原因。
    final collapsedText = !waiting && preview.isNotEmpty ? preview : m.error;
    final collapsed = collapsedText == null
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: MiuixText(
              collapsedText,
              fontSize: preview.isNotEmpty ? 13 : 12,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              color: colors.onSurfaceVariantSummary,
            ),
          );

    final card = HighlightCard(
      highlighted: m.adopted,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      // 卡片内容必须在卡片内部完整排版：不要用 IntrinsicHeight 估算高度
      //（Markdown / 公式的固有高度不准，会导致内容溢出、与边框重叠）。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          ClipRect(
            child: AnimatedSize(
              duration: Motion.medium,
              curve: Motion.curve,
              alignment: Alignment.topCenter,
              // 折叠摘要与展开全文不交叠：旧内容先快速淡出，新内容随后淡入。
              child: AnimatedSwitcher(
                duration: Motion.medium,
                reverseDuration: const Duration(milliseconds: 90),
                switchInCurve: const Interval(0.3, 1, curve: Curves.easeOut),
                switchOutCurve: Curves.easeIn,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topLeft,
                  children: [
                    for (final p in previous)
                      Positioned(left: 0, right: 0, top: 0, child: p),
                    ?current,
                  ],
                ),
                child: waiting
                    ? const SizedBox(
                        key: ValueKey('waiting'),
                        width: double.infinity,
                      )
                    : expanded
                    ? Padding(
                        key: const ValueKey('expanded'),
                        padding: const EdgeInsets.only(top: 8),
                        child: AssistantMessage(message: m, showHeader: false),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('collapsed'),
                        child: collapsed,
                      ),
              ),
            ),
          ),
        ],
      ),
    );

    // 时间线：连接线用 Positioned 跟随卡片的真实高度，不参与卡片排版。
    return AnchorTop(
      active: _anchoring,
      child: Stack(
        children: [
          if (!widget.isLast)
            Positioned(
              left: (_rail - 2) / 2,
              top: _badgeTop + _badge + 4,
              bottom: 0,
              child: Container(width: 2, color: colors.dividerLine),
            ),
          Positioned(
            left: (_rail - _badge) / 2,
            top: _badgeTop,
            child: AnimatedContainer(
              duration: Motion.medium,
              width: _badge,
              height: _badge,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: waiting ? colors.surfaceContainerHigh : colors.primary,
              ),
              child: MiuixText(
                '${widget.number}',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: waiting
                    ? colors.onSurfaceVariantSummary
                    : colors.onPrimary,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              left: _rail + 8,
              bottom: widget.isLast ? 0 : 10,
            ),
            child: card,
          ),
        ],
      ),
    );
  }
}
