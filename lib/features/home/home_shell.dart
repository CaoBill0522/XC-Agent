import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/layout.dart';
import '../../ui/motion.dart';
import '../chat/chat_page.dart';
import '../conversations/conversation_list.dart';
import '../settings/settings_page.dart';
import '../../ui/top_bar_text.dart';

/// 根布局：窄屏 = 会话列表页 → push 聊天页；宽屏 = 侧边栏 + 右侧内容。
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    return isWideLayout(context) ? const _WideLayout() : const _NarrowHome();
  }
}

// ──────────────────────────────── 窄屏（手机）

class _NarrowHome extends ConsumerStatefulWidget {
  const _NarrowHome();

  @override
  ConsumerState<_NarrowHome> createState() => _NarrowHomeState();
}

class _NarrowHomeState extends ConsumerState<_NarrowHome> {
  final _scrollBehavior = MiuixExitUntilCollapsedScrollBehavior();

  void _openChat(String id) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatPage(conversationId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return MiuixScaffold(
      topBar: TopBarTextFix(
        child: MiuixTopAppBar(
          title: 'Agent',
          scrollBehavior: _scrollBehavior,
          actions: [
            AppIconButton(
              icon: AppIcons.settings,
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
            ),
          ],
        ),
      ),
      content: (padding) => Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MiuixScrollBehaviorListener(
              behavior: _scrollBehavior,
              child: ConversationList(
                padding: padding.copyWith(bottom: padding.bottom + 96),
                onOpen: _openChat,
              ),
            ),
            // 新建按钮自己定位：miuix 脚手架把 FAB 放在「12 + 底部安全区」处，
            // iPhone 上底边距 46、右边距 12，不对称。这里让右、下边距相等。
            CornerFab(
              child: MiuixFloatingActionButton(
                onPressed: () async => _openChat(await createConversation(ref)),
                child: MiuixIcon(vector: AppIcons.add, tint: colors.onPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 右下角悬浮按钮：到屏幕右边和底边的距离相等。
///
/// iOS 底部安全区里只有一条很细的 Home 指示条，按钮可以压住安全区，距离取 24
/// （与屏幕圆角大致同心）；其它平台底部可能是导航按钮，必须避开，距离取
/// 「底部安全区 + 12」与 24 中的较大值，右边距同步加大以保持相等。
class CornerFab extends StatelessWidget {
  const CornerFab({super.key, required this.child});

  final Widget child;

  static double gapFor(TargetPlatform platform, EdgeInsets safe) =>
      platform == TargetPlatform.iOS ? 24 : math.max(24, safe.bottom + 12);

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final gap = gapFor(Theme.of(context).platform, safe);
    return Positioned(right: gap + safe.right, bottom: gap, child: child);
  }
}

// ──────────────────────────────── 宽屏（桌面 / 平板横屏）

enum _Pane { chat, settings }

class _WideLayout extends ConsumerStatefulWidget {
  const _WideLayout();

  @override
  ConsumerState<_WideLayout> createState() => _WideLayoutState();
}

class _WideLayoutState extends ConsumerState<_WideLayout> {
  _Pane _pane = _Pane.chat;

  // 右侧内容区自带 Navigator：设置子页等在右栏内 push，不盖住侧边栏。

  // 每次侧边栏操作 +1。异步新建会话完成时若期间用户已点了别处，就不再抢回右栏。
  int _navSeq = 0;

  void _showChat(String id) {
    _navSeq++;
    ref.read(selectedConversationProvider.notifier).select(id);
    setState(() => _pane = _Pane.chat);
  }

  void _showSettings() {
    _navSeq++;
    setState(() => _pane = _Pane.settings);
  }

  Future<void> _newChat() async {
    final seq = ++_navSeq;
    final id = await createConversation(ref);
    if (mounted && seq == _navSeq) _showChat(id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final conversations = ref.watch(conversationsProvider).value;
    var selectedId = ref.watch(selectedConversationProvider);
    // 选中的会话已被删除时回到空白页。
    if (selectedId != null &&
        conversations != null &&
        !conversations.any((c) => c.id == selectedId)) {
      selectedId = null;
    }

    final Widget pane = switch (_pane) {
      _Pane.settings => const SettingsPage(embedded: true),
      _Pane.chat when selectedId != null => ChatPage(
        key: ValueKey(selectedId),
        conversationId: selectedId,
        embedded: true,
      ),
      _Pane.chat => const _EmptyPane(),
    };

    return MiuixScaffold(
      content: (_) => Material(
        type: MaterialType.transparency,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: kSidebarWidth,
              child: ColoredBox(
                color: theme.colors.surfaceContainer,
                child: SafeArea(
                  right: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: MiuixText(
                                'Agent',
                                style: theme.textStyles.title3,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            AppIconButton(
                              icon: AppIcons.add,
                              onPressed: _newChat,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ConversationList(
                          selectedId: _pane == _Pane.chat ? selectedId : null,
                          onOpen: _showChat,
                        ),
                      ),
                      const MiuixHorizontalDivider(),
                      MiuixBasicComponent(
                        title: '设置',
                        insideMargin: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        startAction: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: MiuixIcon(vector: AppIcons.settings, size: 22),
                        ),
                        holdDownState: _pane == _Pane.settings,
                        onClick: _showSettings,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const MiuixVerticalDivider(),
            Expanded(
              // 切换会话 / 设置时淡入淡出；每个 pane 有自己的 Navigator，
              // 设置子页在右栏内压栈，不盖住侧边栏。
              child: FadeSwitch(
                switchKey: '$_pane-$selectedId',
                animateSize: false,
                child: Navigator(
                  key: ValueKey('$_pane-$selectedId'),
                  pages: [MaterialPage(child: pane)],
                  onDidRemovePage: (_) {},
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane();

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return MiuixSurface(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiuixIcon(
              vector: AppIcons.messages,
              size: 48,
              tint: colors.onSurfaceVariantSummary,
            ),
            const SizedBox(height: 12),
            MiuixText('选择一个对话，或点击 + 新建', color: colors.onSurfaceVariantSummary),
          ],
        ),
      ),
    );
  }
}
