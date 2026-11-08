import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 宽度达到此值时切换为桌面双栏布局（侧边栏 + 内容）。
const double kWideBreakpoint = 840;

/// 桌面双栏时侧边栏宽度。
const double kSidebarWidth = 300;

bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kWideBreakpoint;

/// 是否桌面平台（决定 Enter 发送、拖拽、粘贴图片等交互）。
bool get isDesktopPlatform =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

/// 聊天内容的最大宽度（宽屏时居中，避免一行过长）。
const double kChatMaxWidth = 860;

/// 聊天区左右留白：消息列表与输入栏共用，保证两者左右边缘对齐。
double chatGutter(BuildContext context, double width) {
  final base = isWideLayout(context) ? 32.0 : 16.0;
  final centered = (width - kChatMaxWidth) / 2;
  return centered > base ? centered : base;
}
