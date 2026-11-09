import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_service.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../ui/animated_keyed_list.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/motion.dart';
import '../../l10n/tr.dart';

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
    final folders = ref.watch(foldersProvider).value ?? const <Folder>[];
    var filter = ref.watch(folderFilterProvider);
    // 筛选的文件夹已被删除（如在别的设备上）时回到全部。
    if (filter != null && !folders.any((f) => f.id == filter)) filter = null;

    return conversations.when(
      loading: () => const SizedBox.expand(),
      error: (e, _) => Center(child: MiuixText(trArgs('加载失败：{0}', [e]))),
      data: (all) {
        final items = filter == null
            ? all
            : [
                for (final c in all)
                  if (c.folderId == filter) c,
              ];
        // 列表始终保留（新建 / 删除时才有增删动画），空状态叠在上面淡入淡出。
        return Stack(
          children: [
            AnimatedKeyedList<Conversation>(
              // 切换文件夹时整体换一个列表，不对每一项播放增删动画。
              key: ValueKey(filter),
              header: folders.isEmpty
                  ? null
                  : FolderBar(folders: folders, selected: filter),
              items: items,
              keyOf: (c) => c.id,
              padding: padding,
              itemBuilder: (context, c) => _ConversationTile(
                conversation: c,
                selected: c.id == selectedId,
                onTap: () => onOpen(c.id),
              ),
            ),
            // 空状态只是提示，不拦截点击（文件夹筛选条还在它下面）。
            IgnorePointer(
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
                          filter == null ? tr('还没有对话') : tr('这个文件夹还没有对话'),
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
      title: ChatService.displayTitle(c.title),
      actions: [
        SheetAction(tr('重命名'), () async {
          final t = await showTextInput(
            context,
            title: tr('重命名'),
            initial: ChatService.displayTitle(c.title),
          );
          if (t != null) await service.rename(c.id, t);
        }, icon: AppIcons.rename),
        SheetAction(
          c.folderId == null ? tr('移到文件夹') : tr('移到其他文件夹'),
          () => _moveToFolder(context, ref, c),
          icon: AppIcons.moveFile,
        ),
        SheetAction(
          c.pinned ? tr('取消置顶') : tr('置顶'),
          () => service.setPinned(c.id, !c.pinned),
          icon: c.pinned ? AppIcons.unpin : AppIcons.pin,
        ),
        SheetAction(
          tr('删除'),
          () async {
            final ok = await showConfirm(
              context,
              title: tr('删除对话'),
              message: trArgs('「{0}」及其中的图片将被永久删除。', [
                ChatService.displayTitle(c.title),
              ]),
              confirmText: tr('删除'),
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
            title: ChatService.displayTitle(conversation.title),
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

Future<void> _moveToFolder(
  BuildContext context,
  WidgetRef ref,
  Conversation c,
) async {
  final service = ref.read(chatServiceProvider);
  final folders = ref.read(foldersProvider).value ?? const <Folder>[];
  await showActionSheet(
    context,
    title: tr('移到文件夹'),
    actions: [
      for (final f in folders)
        if (f.id != c.folderId)
          SheetAction(
            f.name,
            () => service.moveToFolder(c.id, f.id),
            icon: AppIcons.folder,
          ),
      if (c.folderId != null)
        SheetAction(
          tr('移出文件夹'),
          () => service.moveToFolder(c.id, null),
          icon: AppIcons.messages,
        ),
      SheetAction(tr('新建文件夹…'), () async {
        final name = await showTextInput(context, title: tr('新建文件夹'));
        if (name == null || name.trim().isEmpty) return;
        final id = await service.createFolder(name);
        await service.moveToFolder(c.id, id);
      }, icon: AppIcons.addFolder),
    ],
  );
}

/// 会话列表顶部的文件夹筛选条：全部 + 各文件夹，长按文件夹可重命名 / 删除。
class FolderBar extends ConsumerWidget {
  const FolderBar({super.key, required this.folders, required this.selected});

  final List<Folder> folders;
  final String? selected;

  Future<void> _actions(BuildContext context, WidgetRef ref, Folder f) {
    final service = ref.read(chatServiceProvider);
    return showActionSheet(
      context,
      title: f.name,
      actions: [
        SheetAction(tr('重命名'), () async {
          final t = await showTextInput(
            context,
            title: tr('重命名文件夹'),
            initial: f.name,
          );
          if (t != null && t.trim().isNotEmpty) {
            await service.renameFolder(f.id, t);
          }
        }, icon: AppIcons.rename),
        SheetAction(
          tr('删除文件夹'),
          () async {
            final ok = await showConfirm(
              context,
              title: tr('删除文件夹'),
              message: trArgs('「{0}」里的对话会移回「全部」，不会被删除。', [f.name]),
              confirmText: tr('删除'),
              destructive: true,
            );
            if (!ok) return;
            if (ref.read(folderFilterProvider) == f.id) {
              ref.read(folderFilterProvider.notifier).select(null);
            }
            await service.deleteFolder(f.id);
          },
          icon: AppIcons.delete,
          destructive: true,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void select(String? id) =>
        ref.read(folderFilterProvider.notifier).select(id);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        children: [
          _FolderChip(
            label: tr('全部'),
            selected: selected == null,
            onTap: () => select(null),
          ),
          for (final f in folders)
            _FolderChip(
              label: f.name,
              selected: selected == f.id,
              onTap: () => select(f.id),
              onLongPress: () => _actions(context, ref, f),
            ),
        ],
      ),
    );
  }
}

class _FolderChip extends StatelessWidget {
  const _FolderChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: selected ? colors.primary : colors.surfaceContainerHigh,
            shape: const StadiumBorder(),
          ),
          child: MiuixText(
            label,
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? colors.onPrimary : colors.onSurface,
          ),
        ),
      ),
    );
  }
}

String formatRelativeTime(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return tr('刚刚');
  if (diff.inHours < 1) return trArgs('{0} 分钟前', [diff.inMinutes]);
  if (now.year == t.year && now.month == t.month && now.day == t.day) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
  if (now.year == t.year) return trArgs('{0}月{1}日', [t.month, t.day]);
  return '${t.year}/${t.month}/${t.day}';
}
