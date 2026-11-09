import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/ids.dart';
import '../../l10n/tr.dart';
import '../../ui/app_icons.dart';
import '../../ui/links.dart';
import '../../ui/top_bar_text.dart';

/// 可以渲染预览的代码块类型。
enum PreviewKind { html, svg, mermaid }

/// 按代码块语言（及内容）判断能否预览。
PreviewKind? previewKindOf(String language, String code) {
  final lang = language.trim().toLowerCase();
  final head = code.trimLeft().toLowerCase();
  return switch (lang) {
    'html' || 'htm' || 'xhtml' => PreviewKind.html,
    'svg' => PreviewKind.svg,
    'xml' when head.startsWith('<svg') => PreviewKind.svg,
    'mermaid' || 'mmd' => PreviewKind.mermaid,
    '' when head.startsWith('<!doctype html') || head.startsWith('<html') =>
      PreviewKind.html,
    _ => null,
  };
}

String _escape(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);

/// 把代码块包成完整的网页。
String previewDocument(PreviewKind kind, String code, {required bool dark}) {
  final bg = dark ? '#000000' : '#ffffff';
  final fg = dark ? '#e6e6e6' : '#1a1a1a';
  const viewport =
      '<meta name="viewport" content="width=device-width, initial-scale=1">';
  final base =
      '<meta charset="utf-8">$viewport<style>html,body{margin:0;'
      'background:$bg;color:$fg;font-family:-apple-system,system-ui,sans-serif}'
      '</style>';
  switch (kind) {
    case PreviewKind.html:
      final lower = code.toLowerCase();
      if (lower.contains('<html') || lower.contains('<!doctype')) {
        // 完整文档：只补上视口设置（手机上不缩成一小块）。
        if (lower.contains('name="viewport"')) return code;
        final i = lower.indexOf('<head>');
        if (i >= 0) {
          return '${code.substring(0, i + 6)}$viewport${code.substring(i + 6)}';
        }
        return code;
      }
      return '<!doctype html><html><head>$base<style>body{padding:16px}</style>'
          '</head><body>$code</body></html>';
    case PreviewKind.svg:
      return '<!doctype html><html><head>$base<style>body{display:flex;'
          'justify-content:center;padding:16px}svg{max-width:100%;height:auto}'
          '</style></head><body>$code</body></html>';
    case PreviewKind.mermaid:
      return '<!doctype html><html><head>$base<style>body{padding:16px}'
          '.mermaid{display:flex;justify-content:center}#err{color:#e5484d;'
          'white-space:pre-wrap;font-size:13px}</style>'
          '<script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"></script>'
          '</head><body><pre class="mermaid">${_escape(code)}</pre>'
          '<div id="err"></div><script>'
          "mermaid.initialize({startOnLoad:false,theme:'${dark ? 'dark' : 'default'}'});"
          "mermaid.run().catch(e=>{document.getElementById('err').textContent="
          "${jsonEncode(tr('图表语法有误：'))}+(e.message||e)});"
          '</script></body></html>';
  }
}

/// 应用内 WebView 只在 iOS / Android / macOS 上有；其它平台用系统浏览器打开。
bool get _hasWebView =>
    Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

Future<void> openCodePreview(
  BuildContext context,
  PreviewKind kind,
  String code,
) async {
  final dark = MiuixTheme.of(context).brightness == Brightness.dark;
  final html = previewDocument(kind, code, dark: dark);
  if (!_hasWebView) {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'preview-${newId()}.html'));
    await file.writeAsString(html);
    await launchUrl(Uri.file(file.path));
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => CodePreviewPage(html: html, dark: dark),
    ),
  );
}

class CodePreviewPage extends StatefulWidget {
  const CodePreviewPage({super.key, required this.html, required this.dark});

  final String html;
  final bool dark;

  @override
  State<CodePreviewPage> createState() => _CodePreviewPageState();
}

class _CodePreviewPageState extends State<CodePreviewPage> {
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(widget.dark ? Colors.black : Colors.white)
    ..setNavigationDelegate(
      NavigationDelegate(
        // 页面里的链接不在预览里跳走，用应用内浏览器打开。
        onNavigationRequest: (req) {
          final url = req.url;
          if (url.startsWith('about:') || url.startsWith('data:')) {
            return NavigationDecision.navigate;
          }
          if (req.isMainFrame && url.startsWith('http')) {
            openLink(url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ),
    )
    ..loadHtmlString(widget.html);

  @override
  Widget build(BuildContext context) {
    return MiuixScaffold(
      topBar: TopBarTextFix(
        child: MiuixSmallTopAppBar(
          title: tr('预览'),
          navigationIcon: AppIconButton(
            icon: AppIcons.back,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          actions: [
            AppIconButton(
              icon: AppIcons.refresh,
              onPressed: () => _web.loadHtmlString(widget.html),
            ),
          ],
        ),
      ),
      content: (padding) => Padding(
        padding: EdgeInsets.only(top: padding.top),
        child: WebViewWidget(controller: _web),
      ),
    );
  }
}
