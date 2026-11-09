import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../core/models/capabilities.dart';
import 'vendor/app_text_field.dart';
import 'app_icons.dart';
import 'measure_size.dart';
import 'motion.dart';
import 'top_bar_text.dart';
import '../l10n/tr.dart';

/// 设置类子页面的统一骨架：大标题顶栏 + 返回按钮 + 可滚动内容 + Snackbar。
class SettingsScaffold extends StatefulWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.bottomBar,
    this.snackbar,
    this.showBack = true,
    this.overlays = const [],
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;

  /// 固定在底部的操作区（如「保存」按钮）。
  final Widget? bottomBar;
  final MiuixSnackbarHostState? snackbar;
  final bool showBack;

  /// 对话框等浮层（MiuixOverlayDialog 需要放在树里）。
  final List<Widget> overlays;

  @override
  State<SettingsScaffold> createState() => _SettingsScaffoldState();
}

class _SettingsScaffoldState extends State<SettingsScaffold> {
  final _scrollBehavior = MiuixExitUntilCollapsedScrollBehavior();
  final _bottomHeight = ValueNotifier<double>(0);

  @override
  void dispose() {
    _bottomHeight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MiuixScaffold(
      // 提示浮在底部按钮 / 键盘之上，不遮住保存按钮和输入框。
      snackbarHost: widget.snackbar == null
          ? null
          : SnackbarAbove(
              bottomOccupied: _bottomHeight,
              child: MiuixSnackbarHost(state: widget.snackbar!),
            ),
      topBar: TopBarTextFix(
        child: MiuixTopAppBar(
          title: widget.title,
          scrollBehavior: _scrollBehavior,
          navigationIcon: widget.showBack
              ? AppIconButton(
                  icon: AppIcons.back,
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              : null,
          actions: widget.actions,
        ),
      ),
      content: (padding) => Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: MiuixScrollBehaviorListener(
                    behavior: _scrollBehavior,
                    child: ListView(
                      padding: padding.copyWith(
                        bottom:
                            (widget.bottomBar == null ? padding.bottom : 0) +
                            24,
                      ),
                      children: widget.children,
                    ),
                  ),
                ),
                // 底部区域：有按钮时是按钮（随键盘上移）；没有按钮时是键盘占位，
                // 让列表在键盘弹出时缩短，底部的输入框不会被键盘挡住。
                MeasureSize(
                  onChange: (s) => _bottomHeight.value = s.height,
                  child: widget.bottomBar != null
                      ? Padding(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            8,
                            16,
                            12 +
                                (media.viewInsets.bottom > 0
                                    ? media.viewInsets.bottom
                                    : media.padding.bottom),
                          ),
                          child: widget.bottomBar,
                        )
                      : SizedBox(
                          width: double.infinity,
                          height: media.viewInsets.bottom,
                        ),
                ),
              ],
            ),
            ...widget.overlays,
          ],
        ),
      ),
    );
  }
}

/// 一组卡片包裹的设置项。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) MiuixSmallTitle(title!),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: MiuixCard(
            child: AnimatedSize(
              duration: Motion.medium,
              curve: Motion.curve,
              alignment: Alignment.topCenter,
              child: Column(children: children),
            ),
          ),
        ),
      ],
    );
  }
}

/// 卡片里的输入框行。
class SettingsField extends StatelessWidget {
  const SettingsField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.trailing,
    this.keyboardType,
    this.onChanged,
    this.autocorrect = false,
  });

  final TextEditingController controller;
  final String label;

  /// 输入框下方的说明文字。
  final String? hint;
  final bool obscure;
  final Widget? trailing;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  /// 默认关闭：设置项多为 URL / Key / 模型名，被系统纠错会出错。
  final bool autocorrect;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(
            controller: controller,
            label: label,
            singleLine: true,
            obscureText: obscure,
            autocorrect: autocorrect,
            enableSuggestions: autocorrect,
            trailingIcon: trailing,
            keyboardType: keyboardType,
            onChanged: onChanged,
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: MiuixText(
                hint!,
                fontSize: 12,
                color: colors.onSurfaceVariantSummary,
              ),
            ),
        ],
      ),
    );
  }
}

/// 能力小标签行。
class CapabilityBadges extends StatelessWidget {
  const CapabilityBadges(this.capabilities, {super.key, this.extra = const []});

  final Set<ModelCapability> capabilities;
  final List<String> extra;

  @override
  Widget build(BuildContext context) {
    final labels = [
      for (final c in ModelCapability.values)
        if (capabilities.contains(c)) c.label,
      ...extra,
    ];
    if (labels.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [for (final l in labels) _Tag(l)],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.primary.withValues(alpha: 0.12),
        shape: const MiuixSquircleBorder(cornerRadius: 6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: MiuixText(text, fontSize: 11, color: colors.primary),
      ),
    );
  }
}

/// 页面底部的主按钮。
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.loading = false,
    this.enabled = true,
  });

  final String text;
  final VoidCallback onPressed;
  final bool loading;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return SizedBox(
      width: double.infinity,
      child: MiuixButton(
        onPressed: onPressed,
        enabled: enabled && !loading,
        colors: MiuixButtonDefaults.buttonColorsPrimary(context),
        child: FadeSwitch(
          switchKey: loading,
          animateSize: false,
          alignment: Alignment.center,
          child: MiuixText(
            loading ? tr('请稍候…') : text,
            color: colors.onPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 确认对话框（放进 [SettingsScaffold.overlays]）。
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.show,
    required this.title,
    required this.message,
    required this.confirmText,
    required this.onConfirm,
    required this.onCancel,
    this.destructive = false,
  });

  final bool show;
  final String title;
  final String message;
  final String confirmText;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return MiuixOverlayDialog(
      show: show,
      title: title,
      summary: message,
      onDismissRequest: onCancel,
      content: Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Row(
          children: [
            Expanded(child: MiuixTextButton(tr('取消'), onPressed: onCancel)),
            const SizedBox(width: 12),
            Expanded(
              child: MiuixTextButton(
                confirmText,
                onPressed: onConfirm,
                colors: destructive
                    ? null
                    : MiuixButtonDefaults.buttonColorsPrimary(context),
                textStyle: destructive
                    ? TextStyle(color: theme.colors.error)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
