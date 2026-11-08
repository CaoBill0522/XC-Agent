import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../ui/animated_keyed_list.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/motion.dart';

/// 会话列表，手机首页和桌面侧边栏共用。
class ConversationList extends ConsumerWidget {
  const ConversationList({
    super.key,
    required this.onOpen,
    this.selectedId,
    this.padding = EdgeInsets.zero,
  });

  final ValueChanged<String> onOpen;
  final String? selectedId;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final conversations = ref.watch(conversationsProvider);

    return conversations.when(
      loading: () => const SizedBox.expand(),
      error: (e, _) => Center(child: MiuixText('加载失败：$e')),
      data: (items) {
        // 列表始终保留（新建 / 删除时才有增删动画），空状态叠在上面淡入淡出。
        return Stack(
          children: [
            AnimatedKeyedList<Conversation>(
              items: items,
              keyOf: (c) => c.id,
              padding: padding,
              itemBuilder: (context, c) => _ConversationTile(
                conversation: c,
                selected: c.id == selectedId,
                onTap: () => onOpen(c.id),
              ),
            ),
            IgnorePointer(
              ignoring: items.isNotEmpty,
              child: AnimatedOpacity(
                opacity: items.isEmpty ? 1 : 0,
                duration: Motion.medium,
                child: Padding(
                  padding: padding,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MiuixIcon(
                          vector: AppIcons.messages,
                          size: 40,
                          tint: colors.onSurfaceVariantSummary,
                        ),
                        const SizedBox(height: 12),
                        MiuixText(
                          '还没有对话',
                          color: colors.onSurfaceVariantSummary,
                          fontSize: 14,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;

  Future<void> _actions(BuildContext context, WidgetRef ref) {
    final service = ref.read(chatServiceProvider);
    final c = conversation;
    return showActionSheet(
      context,
      title: c.title,
      actions: [
        SheetAction('重命名', () async {
          final t = await showTextInput(
            context,
            title: '重命名',
            initial: c.title,
          );
          if (t != null) await service.rename(c.id, t);
        }, icon: AppIcons.rename),
        SheetAction(
          c.pinned ? '取消置顶' : '置顶',
          () => service.setPinned(c.id, !c.pinned),
          icon: c.pinned ? AppIcons.unpin : AppIcons.pin,
        ),
        SheetAction(
          '删除',
          () async {
            final ok = await showConfirm(
              context,
              title: '删除对话',
              message: '「${c.title}」及其中的图片将被永久删除。',
              confirmText: '删除',
              destructive: true,
            );
            if (ok) {
              if (ref.read(selectedConversationProvider) == c.id) {
                ref.read(selectedConversationProvider.notifier).select(null);
              }
              await service.deleteConversation(c.id);
            }
          },
          icon: AppIcons.delete,
          destructive: true,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    return GestureDetector(
      onLongPress: () => _actions(context, ref),
      onSecondaryTap: () => _actions(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        // 选中背景平滑过渡（MiuixCard 的颜色不带动画）。
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.curve,
          decoration: ShapeDecoration(
            color: selected
                ? colors.surfaceContainerHigh
                : colors.surfaceContainerHigh.withValues(alpha: 0),
            shape: const MiuixSquircleBorder(cornerRadius: 14),
          ),
          child: MiuixBasicComponent(
            title: conversation.title,
            summary: formatRelativeTime(conversation.updatedAt),
            insideMargin: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            endActions: [
              if (conversation.pinned)
                MiuixIcon(
                  vector: AppIcons.pin,
                  size: 16,
                  tint: colors.onSurfaceVariantSummary,
                ),
            ],
            onClick: onTap,
          ),
        ),
      ),
    );
  }
}

String formatRelativeTime(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (now.year == t.year && now.month == t.month && now.day == t.day) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
  if (now.year == t.year) return '${t.month}月${t.day}日';
  return '${t.year}/${t.month}/${t.day}';
}
