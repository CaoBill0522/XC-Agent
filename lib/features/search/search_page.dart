import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_service.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/layout.dart';
import '../../ui/motion.dart';
import '../../ui/top_bar_text.dart';
import '../../ui/vendor/app_text_field.dart';
import '../conversations/conversation_list.dart';
import '../../l10n/tr.dart';

/// 打开对话时要定位并高亮的消息（搜索结果跳转）。
class PendingFocus {
  final _focus = <String, String>{};
  void put(String convId, String messageId) => _focus[convId] = messageId;
  String? take(String convId) => _focus.remove(convId);
}

final pendingFocusProvider = Provider<PendingFocus>((ref) => PendingFocus());

/// 全局搜索：对话标题和所有消息内容。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, required this.onOpen});

  /// 打开某个对话（窄屏压栈，宽屏切换右栏）。
  final void Function(String conversationId) onOpen;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<SearchHit>? _hits;
  String _searched = '';

  @override
  void initState() {
    super.initState();
    _query.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _run);
  }

  Future<void> _run() async {
    final q = _query.text.trim();
    if (q == _searched) return;
    _searched = q;
    final hits = q.isEmpty
        ? null
        : await ref.read(chatServiceProvider).search(q);
    if (mounted && q == _searched) setState(() => _hits = hits);
  }

  void _open(SearchHit hit) {
    if (hit.messageId != null) {
      ref.read(pendingFocusProvider).put(hit.conversation.id, hit.messageId!);
    }
    widget.onOpen(hit.conversation.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final hits = _hits;
    return MiuixScaffold(
      topBar: TopBarTextFix(
        child: MiuixSmallTopAppBar(
          title: tr('搜索'),
          navigationIcon: AppIconButton(
            icon: AppIcons.back,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
      content: (padding) => Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: EdgeInsets.only(top: padding.top),
          child: LayoutBuilder(
            builder: (context, box) {
              final gutter = chatGutter(context, box.maxWidth);
              return Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 8),
                    child: AppTextField(
                      controller: _query,
                      label: tr('搜索对话标题和内容'),
                      useLabelAsPlaceholder: true,
                      autofocus: true,
                      singleLine: true,
                      autocorrect: false,
                      cornerRadius: 22,
                      leadingIcon: Padding(
                        padding: const EdgeInsets.only(left: 14, right: 4),
                        child: MiuixIcon(
                          vector: AppIcons.search,
                          size: 18,
                          tint: colors.onSurfaceVariantSummary,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: FadeSwitch(
                      switchKey: hits == null
                          ? 'idle'
                          : hits.isEmpty
                          ? 'empty'
                          : 'hits',
                      animateSize: false,
                      child: hits == null
                          ? const SizedBox.expand()
                          : hits.isEmpty
                          ? Center(
                              child: MiuixText(
                                trArgs('没有找到「{0}」', [_searched]),
                                color: colors.onSurfaceVariantSummary,
                              ),
                            )
                          : ListView.builder(
                              padding: EdgeInsets.fromLTRB(
                                gutter - 12,
                                0,
                                gutter - 12,
                                padding.bottom + 16,
                              ),
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              itemCount: hits.length,
                              itemBuilder: (_, i) =>
                                  _HitTile(hit: hits[i], onTap: _open),
                            ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({required this.hit, required this.onTap});

  final SearchHit hit;
  final ValueChanged<SearchHit> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final s = hit.snippet;
    final start = hit.matchStart.clamp(0, s.length);
    final end = (start + hit.matchLength).clamp(0, s.length);
    final base = TextStyle(
      fontSize: 14,
      height: 1.45,
      color: colors.onSurfaceVariantSummary,
    );
    final titleHit = hit.messageId == null;
    return Tap(
      sink: false,
      onTap: () => onTap(hit),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: MiuixText(
                    ChatService.displayTitle(hit.conversation.title),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                MiuixText(
                  formatRelativeTime(hit.time ?? hit.conversation.updatedAt),
                  fontSize: 12,
                  color: colors.onSurfaceVariantSummary,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                style: base,
                children: [
                  if (!titleHit)
                    TextSpan(text: hit.role == 'user' ? tr('我：') : tr('回答：')),
                  if (titleHit)
                    TextSpan(text: tr('标题匹配'))
                  else ...[
                    TextSpan(text: s.substring(0, start)),
                    TextSpan(
                      text: s.substring(start, end),
                      style: TextStyle(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(text: s.substring(end)),
                  ],
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
