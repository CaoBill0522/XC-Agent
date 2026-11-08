import 'package:url_launcher/url_launcher.dart';

/// 打开网页链接：手机上用应用内浏览器（iOS 为 Safari 视图，Android 为 Custom Tabs），
/// 看完点「完成」直接回到对话；桌面端不支持应用内浏览器，交给系统浏览器。
/// 非 http(s) 链接（mailto: 等）交给系统处理。
///
/// 返回是否打开成功；链接无效或没有可处理的应用时返回 false，不抛异常
/// （模型输出的链接可能是残缺的，调用方一般不 await）。
Future<bool> openLink(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) return false;
  try {
    final web =
        (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
    final inApp = web && await supportsLaunchMode(LaunchMode.inAppBrowserView);
    return await launchUrl(
      uri,
      mode: inApp
          ? LaunchMode.inAppBrowserView
          : LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}
