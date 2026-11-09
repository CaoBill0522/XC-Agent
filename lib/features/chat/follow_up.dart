import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_error.dart';
import '../../data/chat_service.dart';
import '../../ui/app_icons.dart';
import '../../ui/motion.dart';

/// 「新对话追问」时由原 Agent 流式生成的前文总结。
class SummaryJob extends ChangeNotifier {
  /// 用原回答的 Agent 开始总结。
  factory SummaryJob.start(
    ChatService service,
    String sourceMsgId,
    String selection,
  ) {
    final cancel = CancelToken();
    return SummaryJob(
      service.summarize(sourceMsgId, selection: selection, cancel: cancel),
      cancelToken: cancel,
    );
  }

  /// [stream] 逐步产出当前已生成的完整文字。
  SummaryJob(Stream<String> stream, {this.cancelToken}) {
    _sub = stream.listen(
      (t) {
        text = t;
        notifyListeners();
      },
      onError: (Object e) {
        error = e is ApiException ? e.message : '$e';
        done = true;
        notifyListeners();
      },
      onDone: () {
        done = true;
        notifyListeners();
      },
    );
  }

  final CancelToken? cancelToken;
  late final StreamSubscription<String> _sub;
  String text = '';
  bool done = false;
  String? error;

  bool get loading => !done;

  @override
  void dispose() {
    cancelToken?.cancel();
    _sub.cancel();
    super.dispose();
  }
}

/// 打开某个对话时要预先放进输入栏的内容（新对话追问：引用 + 总结；快捷提问：文字）。
class PendingDraft {
  PendingDraft({this.quote, this.summary, this.text});
  final String? quote;
  final SummaryJob? summary;

  /// 预先填进输入框的文字（快捷指令 / 分享进来的内容）。
  final String? text;

  bool get isFollowUp => quote != null || summary != null;
}

class PendingDrafts {
  final _drafts = <String, PendingDraft>{};
  void put(String convId, PendingDraft d) => _drafts[convId] = d;
  PendingDraft? take(String convId) => _drafts.remove(convId);
}

final pendingDraftsProvider = Provider<PendingDrafts>((ref) => PendingDrafts());

/// 去掉常见 Markdown 标记，用于小卡片里的纯文本预览。
String plainMarkdown(String md) => md
    .replaceAll(RegExp(r'```[^\n]*\n?'), '')
    .replaceAll(RegExp(r'(\*\*|__|\*|`|~~)'), '')
    .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
    .replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '· ')
    .replaceAll(RegExp(r'^>\s?', multiLine: true), '')
    .trim();

/// 聊天页提供给消息组件的追问入口（选中回答文字后的菜单项）。
class ChatActions extends InheritedWidget {
  const ChatActions({
    super.key,
    required this.quoteHere,
    required this.askInNew,
    required this.clearSelections,
    required this.branchFrom,
    required this.shareMessage,
    required super.child,
  });

  /// 从这条消息分出一个新对话。
  final void Function(String msgId) branchFrom;

  /// 导出 / 分享单条回答。
  final void Function(String msgId) shareMessage;

  /// 每次 +1，页面上所有回答清除文字选择（双击采纳时，iOS 的双击选词会顺带
  /// 选中一个词并弹出菜单，需要撤销）。
  final ValueNotifier<int> clearSelections;

  /// 在当前对话追问：把选中内容放到输入框上方。
  final void Function(String selection) quoteHere;

  /// 新开对话追问：用原 Agent 总结前文后在新对话里继续。
  final void Function(String sourceMsgId, String selection) askInNew;

  static ChatActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatActions>();

  @override
  bool updateShouldNotify(ChatActions old) => false;
}

/// 回答正文：可选中，选中后的菜单里加上「追问」「新对话追问」。
class SelectableAnswer extends StatefulWidget {
  const SelectableAnswer({
    super.key,
    required this.messageId,
    required this.enabled,
    required this.child,
  });

  final String messageId;

  /// 回答生成完毕才提供追问（生成中内容还在变）。
  final bool enabled;
  final Widget child;

  @override
  State<SelectableAnswer> createState() => _SelectableAnswerState();
}

class _SelectableAnswerState extends State<SelectableAnswer> {
  String? _selected;
  final _area = GlobalKey<SelectionAreaState>();
  ValueNotifier<int>? _clear;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final clear = ChatActions.maybeOf(context)?.clearSelections;
    if (clear != _clear) {
      _clear?.removeListener(_onClear);
      _clear = clear?..addListener(_onClear);
    }
  }

  @override
  void dispose() {
    _clear?.removeListener(_onClear);
    super.dispose();
  }

  void _onClear() {
    // 双击选词在同一次抬起时完成，等这一帧结束再清。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final region = _area.currentState?.selectableRegion;
      if (region == null || !mounted) return;
      region.hideToolbar();
      region.clearSelection();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 菜单在 Overlay 里构建，拿不到聊天页的 ChatActions，这里先取好。
    final actions = ChatActions.maybeOf(context);
    return SelectionArea(
      key: _area,
      onSelectionChanged: (c) => _selected = c?.plainText,
      contextMenuBuilder: (menuContext, state) {
        final items = [...state.contextMenuButtonItems];
        final sel = _selected?.trim() ?? '';
        if (actions != null && widget.enabled && sel.isNotEmpty) {
          void close() {
            state.hideToolbar();
            state.clearSelection();
          }

          // 放在「复制」之后，最常用的两个操作不用翻页。
          final at = items.isEmpty ? 0 : 1;
          items.insertAll(at, [
            ContextMenuButtonItem(
              label: '追问',
              onPressed: () {
                close();
                actions.quoteHere(sel);
              },
            ),
            ContextMenuButtonItem(
              label: '新对话追问',
              onPressed: () {
                close();
                actions.askInNew(widget.messageId, sel);
              },
            ),
          ]);
        }
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: items,
        );
      },
      child: widget.child,
    );
  }
}

/// 输入框上方的追问附件：前文总结（可展开）+ 引用片段，各自可移除。
class FollowUpAttachments extends StatelessWidget {
  const FollowUpAttachments({
    super.key,
    required this.quote,
    required this.summary,
    required this.onRemoveQuote,
    required this.onRemoveSummary,
  });

  final String? quote;
  final SummaryJob? summary;
  final VoidCallback onRemoveQuote;
  final VoidCallback onRemoveSummary;

  @override
  Widget build(BuildContext context) {
    final summary = this.summary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary != null)
          _SummaryCard(job: summary, onRemove: onRemoveSummary),
        if (summary != null && quote != null) const SizedBox(height: 6),
        if (quote != null) QuoteCard(text: quote!, onRemove: onRemoveQuote),
      ],
    );
  }
}

/// 引用片段：左侧主题色竖条 + 最多 3 行文字。输入框上方和用户消息里共用。
class QuoteCard extends StatelessWidget {
  const QuoteCard({
    super.key,
    required this.text,
    this.onRemove,
    this.maxLines = 3,
  });

  final String text;
  final VoidCallback? onRemove;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: ShapeDecoration(
        color: colors.surfaceContainer,
        shape: const MiuixSquircleBorder(cornerRadius: 12),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 3,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: MiuixText(
                text,
                fontSize: 13,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                color: colors.onSurfaceVariantSummary,
              ),
            ),
            if (onRemove != null) _RemoveButton(onTap: onRemove!),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatefulWidget {
  const _SummaryCard({required this.job, required this.onRemove});

  final SummaryJob job;
  final VoidCallback onRemove;

  @override
  State<_SummaryCard> createState() => _SummaryCardState();
}

class _SummaryCardState extends State<_SummaryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final job = widget.job;
    final status = job.error != null
        ? '总结失败：${job.error}'
        : job.loading
        ? '正在总结前文…'
        : '前文总结（发送时作为背景一起发出）';
    return Tap(
      sink: false,
      onTap: job.text.isEmpty
          ? null
          : () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: ShapeDecoration(
          color: colors.primary.withValues(alpha: 0.06),
          shape: const MiuixSquircleBorder(cornerRadius: 12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (job.loading) ...[
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: MiuixInfiniteProgressIndicator(),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: MiuixText(
                    status,
                    fontSize: 12,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    color: job.error != null ? colors.error : colors.primary,
                  ),
                ),
                _RemoveButton(onTap: widget.onRemove),
              ],
            ),
            if (job.text.isNotEmpty)
              AnimatedSize(
                duration: Motion.medium,
                curve: Motion.curve,
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  // 展开后最多占 40% 屏高，内部可滚动，不把输入框顶出屏幕。
                  constraints: BoxConstraints(
                    maxHeight: _expanded
                        ? MediaQuery.sizeOf(context).height * 0.4
                        : 60,
                  ),
                  child: SingleChildScrollView(
                    physics: _expanded
                        ? null
                        : const NeverScrollableScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, right: 4),
                      child: MiuixText(
                        plainMarkdown(job.text),
                        fontSize: 13,
                        maxLines: _expanded ? null : 3,
                        overflow: _expanded ? null : TextOverflow.ellipsis,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Tap(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: MiuixIcon(
          vector: AppIcons.close,
          size: 14,
          tint: colors.onSurfaceVariantSummary,
        ),
      ),
    );
  }
}
