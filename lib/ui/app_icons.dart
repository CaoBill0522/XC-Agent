import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart';

/// 图标统一入口：业务代码只通过这里取 miuix 图标，换图标库时只改这一处。
class AppIcons {
  AppIcons._();

  static MiuixVectorIcon _ext(String name) => MiuixIcons.extended.byName(name)!;

  static MiuixVectorIcon get add => _ext('add');
  static MiuixVectorIcon get back => _ext('back');
  static MiuixVectorIcon get send => _ext('send');
  static MiuixVectorIcon get settings => _ext('settings');
  static MiuixVectorIcon get image => _ext('image');
  static MiuixVectorIcon get messages => _ext('messages');
  static MiuixVectorIcon get delete => _ext('delete');
  static MiuixVectorIcon get edit => _ext('edit');
  static MiuixVectorIcon get copy => _ext('copy');
  static MiuixVectorIcon get more => _ext('more');
  static MiuixVectorIcon get pin => _ext('pin');
  static MiuixVectorIcon get layers => _ext('layers');
  static MiuixVectorIcon get reply => _ext('reply');
  static MiuixVectorIcon get replyAll => _ext('replyAll');
  static MiuixVectorIcon get sort => _ext('sort');
  static MiuixVectorIcon get theme => _ext('theme');
  static MiuixVectorIcon get info => _ext('info');
  static MiuixVectorIcon get community => _ext('community');
  static MiuixVectorIcon get show => _ext('show');
  static MiuixVectorIcon get hide => _ext('hide');
  static MiuixVectorIcon get refresh => _ext('refresh');
  static MiuixVectorIcon get link => _ext('link');
  static MiuixVectorIcon get download => _ext('download');
  static MiuixVectorIcon get photos => _ext('photos');
  static MiuixVectorIcon get close => _ext('close');
  static MiuixVectorIcon get stop => _ext('pause');
  static MiuixVectorIcon get regenerate => _ext('refresh');

  /// 联网搜索。
  static MiuixVectorIcon get world => MiuixIcons.basic.search;

  /// 向右的箭头，旋转后用作展开 / 收起。
  static MiuixVectorIcon get chevron => MiuixIcons.basic.arrowRight;
  static MiuixVectorIcon get ok => _ext('ok');
  static MiuixVectorIcon get rename => _ext('rename');
  static MiuixVectorIcon get unpin => _ext('unpin');
  static MiuixVectorIcon get favorites => _ext('favorites');
  static MiuixVectorIcon get favoritesFill => _ext('favoritesFill');
  static MiuixVectorIcon get tune => _ext('tune');
  static MiuixVectorIcon get notes => _ext('notes');
  static MiuixVectorIcon get merge => _ext('merge');
  static MiuixVectorIcon get branch => _ext('mindMap');
  static MiuixVectorIcon get share => _ext('share');
  static MiuixVectorIcon get file => _ext('file');
  static MiuixVectorIcon get filter => _ext('filter');
  static MiuixVectorIcon get backup => _ext('backup');
  static MiuixVectorIcon get search => MiuixIcons.basic.search;
  static MiuixVectorIcon get sidebar => MiuixIcons.basic.sidebar;
}

/// 带 miuix 风格的纯图标按钮。
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 24,
    this.tint,
    this.enabled = true,
    this.backgroundColor,
    this.extent = 40,
  });

  final MiuixVectorIcon icon;

  /// 按钮的宽高（点击区域）。
  final double extent;
  final VoidCallback onPressed;
  final double size;
  final Color? tint;
  final bool enabled;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return MiuixIconButton(
      onPressed: onPressed,
      enabled: enabled,
      backgroundColor: backgroundColor,
      minWidth: extent,
      minHeight: extent,
      child: MiuixIcon(vector: icon, size: size, tint: tint),
    );
  }
}
