import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_miuix/miuix.dart';

import 'vendor/app_text_field.dart';
import '../l10n/tr.dart';

/// miuix 的对话框 / 底部面板是声明式的（show 参数控制），这里包装成命令式调用：
/// 推一个透明路由，里面放一个透明 MiuixScaffold 作为弹层宿主。
Future<T?> _showOverlay<T>(
  BuildContext context,
  Widget Function(bool show, void Function([T? result]) close) builder,
) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    PageRouteBuilder<T>(
      opaque: false,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => _OverlayHost<T>(builder: builder),
    ),
  );
}

class _OverlayHost<T> extends StatefulWidget {
  const _OverlayHost({required this.builder});

  final Widget Function(bool show, void Function([T? result]) close) builder;

  @override
  State<_OverlayHost<T>> createState() => _OverlayHostState<T>();
}

class _OverlayHostState<T> extends State<_OverlayHost<T>> {
  bool _show = false;
  bool _closing = false;
  T? _result;

  @override
  void initState() {
    super.initState();
    // 下一帧再显示，触发入场动画。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _show = true);
    });
  }

  void _close([T? result]) {
    if (_closing) return;
    _closing = true;
    _result = result;
    setState(() => _show = false);
    // 等退场动画结束再出栈（onDismissFinished 不一定在所有组件上都有，兜底延时）。
    Future<void>.delayed(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      final nav = Navigator.of(context);
      // 只移除自己这一层：上面若又压了别的路由，不能误关它。
      if (route == null || route.isCurrent) {
        nav.pop(_result);
      } else {
        nav.removeRoute(route, _result);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MiuixScaffold(
      containerColor: Colors.transparent,
      content: (_) => Material(
        type: MaterialType.transparency,
        child: widget.builder(_show, _close),
      ),
    );
  }
}

/// 通用对话框。
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required String title,
  String? summary,
  required Widget Function(
    BuildContext context,
    void Function([T? result]) close,
  )
  content,
}) {
  return _showOverlay<T>(
    context,
    (show, close) => MiuixOverlayDialog(
      show: show,
      title: title,
      summary: summary,
      onDismissRequest: close,
      content: Builder(builder: (ctx) => content(ctx, close)),
    ),
  );
}

/// 对话框底部按钮行。
class DialogButtons extends StatelessWidget {
  const DialogButtons({
    super.key,
    required this.confirmText,
    required this.onConfirm,
    required this.onCancel,
    this.destructive = false,
  });

  final String confirmText;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        children: [
          Expanded(child: MiuixTextButton(tr('取消'), onPressed: onCancel)),
          SizedBox(width: 12),
          Expanded(
            child: MiuixTextButton(
              confirmText,
              onPressed: onConfirm,
              colors: destructive
                  ? null
                  : MiuixButtonDefaults.buttonColorsPrimary(context),
              textStyle: destructive ? TextStyle(color: colors.error) : null,
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> showConfirm(
  BuildContext context, {
  required String title,
  String? message,
  String? confirmText,
  bool destructive = false,
}) async {
  final r = await showAppDialog<bool>(
    context,
    title: title,
    summary: message,
    content: (ctx, close) => DialogButtons(
      confirmText: confirmText ?? tr('确定'),
      destructive: destructive,
      onConfirm: () => close(true),
      onCancel: () => close(false),
    ),
  );
  return r ?? false;
}

Future<String?> showTextInput(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = '',
  bool multiline = false,
  bool autocorrect = true,
}) {
  final controller = TextEditingController(text: initial);
  return showAppDialog<String>(
    context,
    title: title,
    content: (ctx, close) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        AppTextField(
          controller: controller,
          label: label,
          useLabelAsPlaceholder: true,
          autofocus: true,
          autocorrect: autocorrect,
          enableSuggestions: autocorrect,
          singleLine: !multiline,
          minLines: multiline ? 3 : null,
          maxLines: multiline ? 10 : null,
          onSubmitted: multiline ? null : (v) => close(v),
        ),
        DialogButtons(
          confirmText: tr('确定'),
          onConfirm: () => close(controller.text),
          onCancel: close,
        ),
      ],
    ),
  ).whenComplete(
    () => WidgetsBinding.instance.addPostFrameCallback(
      (_) => controller.dispose(),
    ),
  );
}

/// 通用底部面板：[builder] 里调用 close(result) 关闭并返回结果。
/// 内容过高时可滚动。
Future<T?> showAppSheet<T>(
  BuildContext context, {
  String? title,
  required Widget Function(
    BuildContext context,
    void Function([T? result]) close,
  )
  builder,
}) {
  return _showOverlay<T>(
    context,
    (show, close) => MiuixOverlayBottomSheet(
      show: show,
      title: title,
      onDismissRequest: close,
      content: Builder(
        builder: (ctx) => Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: builder(ctx, close),
        ),
      ),
    ),
  );
}

class SheetAction {
  const SheetAction(
    this.label,
    this.onTap, {
    this.icon,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onTap;
  final MiuixVectorIcon? icon;
  final bool destructive;
}

/// 底部操作菜单（长按 / 右键菜单）。菜单完全关闭后才执行所选操作。
Future<void> showActionSheet(
  BuildContext context, {
  String? title,
  required List<SheetAction> actions,
}) async {
  final picked = await _showOverlay<SheetAction>(
    context,
    (show, close) => MiuixOverlayBottomSheet(
      show: show,
      title: title,
      onDismissRequest: close,
      content: Builder(
        builder: (ctx) {
          final colors = MiuixTheme.of(ctx).colors;
          // 面板内容左右各有 24 的内边距（insideMargin），底部也留 24，
          // 让深色卡片左、右、下三边等宽。
          return Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: MiuixCard(
              colors: MiuixCardColors(
                color: colors.surfaceContainerHigh,
                contentColor: colors.onSurface,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final a in actions)
                    MiuixBasicComponent(
                      title: a.label,
                      titleColor: a.destructive
                          ? MiuixBasicComponentColors(
                              color: colors.error,
                              disabledColor: colors.disabledOnSurface,
                            )
                          : null,
                      startAction: a.icon == null
                          ? null
                          : Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: MiuixIcon(
                                vector: a.icon,
                                size: 22,
                                tint: a.destructive
                                    ? colors.error
                                    : colors.onSurface,
                              ),
                            ),
                      onClick: () => close(a),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
  picked?.onTap();
}
