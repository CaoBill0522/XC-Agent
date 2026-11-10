import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/tr.dart';
import '../../ui/app_icons.dart';
import '../../ui/links.dart';
import '../../ui/settings_widgets.dart';

const githubUrl = 'https://github.com/CaoBill0522/XCAgent';
const websiteUrl = 'https://agent.oxoz.cn';
const copyrightHolder = 'Jiacheng Cao';

/// 官网上的页面（隐私政策、使用条款、用户支持），按界面语言打开中文或英文版。
String sitePage(String page) =>
    '$websiteUrl/$page${L10n.isEn ? '?lang=en' : '?lang=zh'}';
const copyrightYear = 2026;

/// 鸣谢：用到的主要开源项目（名称、用途、许可证、主页）。
const credits = <(String, String, String, String)>[
  ('Flutter', '跨平台界面框架', 'BSD-3-Clause', 'https://flutter.dev'),
  (
    'flutter_miuix',
    'HyperOS 风格的界面组件和动效',
    'Apache-2.0',
    'https://pub.dev/packages/flutter_miuix',
  ),
  ('Riverpod', '状态管理', 'MIT', 'https://riverpod.dev'),
  ('drift', '本地数据库', 'MIT', 'https://pub.dev/packages/drift'),
  ('dio', '网络请求', 'MIT', 'https://pub.dev/packages/dio'),
  (
    'gpt_markdown',
    'Markdown 与公式渲染',
    'BSD-3-Clause',
    'https://pub.dev/packages/gpt_markdown',
  ),
  ('Mermaid', '流程图预览', 'MIT', 'https://mermaid.js.org'),
  (
    'speech_to_text',
    '语音输入',
    'BSD-3-Clause',
    'https://pub.dev/packages/speech_to_text',
  ),
  ('record', '录音（模型转写）', 'BSD-3-Clause', 'https://pub.dev/packages/record'),
  (
    'webview_flutter',
    '代码预览',
    'BSD-3-Clause',
    'https://pub.dev/packages/webview_flutter',
  ),
  (
    'flutter_secure_storage',
    '在系统钥匙串里保存 API Key',
    'BSD-3-Clause',
    'https://pub.dev/packages/flutter_secure_storage',
  ),
  ('local_auth', '应用锁', 'BSD-3-Clause', 'https://pub.dev/packages/local_auth'),
  ('image', '图片压缩', 'MIT', 'https://pub.dev/packages/image'),
  (
    'share_plus · gal · image_picker · file_selector',
    '分享、保存图片、选择图片和文件',
    'BSD-3-Clause / Apache-2.0',
    'https://pub.dev/packages/share_plus',
  ),
  (
    'url_launcher · app_links · quick_actions',
    '打开链接、快捷入口',
    'BSD-3-Clause / Apache-2.0',
    'https://pub.dev/packages/url_launcher',
  ),
  (
    'pasteboard · desktop_drop',
    '粘贴和拖入图片',
    'Apache-2.0',
    'https://pub.dev/packages/pasteboard',
  ),
];

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((i) {
          if (mounted) setState(() => _info = i);
        })
        .catchError((_) {});
  }

  String get _version {
    final i = _info;
    if (i == null) return '';
    return i.buildNumber.isEmpty
        ? trArgs('版本 {0}', [i.version])
        : trArgs('版本 {0}（{1}）', [i.version, i.buildNumber]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final dark = MiuixTheme.of(context).brightness == Brightness.dark;
    Widget leading(Widget w) =>
        Padding(padding: const EdgeInsets.only(right: 14), child: w);

    return SettingsScaffold(
      title: tr('关于'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Column(
            children: [
              DecoratedBox(
                decoration: ShapeDecoration(
                  shape: MiuixSquircleBorder(
                    cornerRadius: 26,
                    side: BorderSide(color: colors.dividerLine),
                  ),
                ),
                child: ClipPath(
                  clipper: const ShapeBorderClipper(
                    shape: MiuixSquircleBorder(cornerRadius: 26),
                  ),
                  child: Image.asset(
                    dark
                        ? 'assets/brand/logo_dark.png'
                        : 'assets/brand/logo_light.png',
                    width: 96,
                    height: 96,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              MiuixText(
                'XCAgent',
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
              const SizedBox(height: 4),
              MiuixText(
                _version,
                fontSize: 13,
                color: colors.onSurfaceVariantSummary,
              ),
              const SizedBox(height: 12),
              MiuixText(
                tr('支持 OpenAI / Anthropic 格式的多模型 AI 客户端'),
                fontSize: 14,
                textAlign: TextAlign.center,
                color: colors.onSurfaceVariantSummary,
              ),
            ],
          ),
        ),
        SettingsGroup(
          children: [
            MiuixArrowPreference(
              title: 'GitHub',
              summary: 'github.com/CaoBill0522/XCAgent',
              startAction: leading(
                Image.asset(
                  'assets/brand/github.png',
                  width: 24,
                  height: 24,
                  color: colors.onSurface,
                ),
              ),
              onClick: () => openLink(githubUrl),
            ),
            MiuixArrowPreference(
              title: tr('官网'),
              summary: 'agent.oxoz.cn',
              startAction: leading(
                MiuixIcon(
                  vector: AppIcons.link,
                  size: 24,
                  tint: colors.onSurface,
                ),
              ),
              onClick: () => openLink(websiteUrl),
            ),
          ],
        ),
        SettingsGroup(
          children: [
            MiuixArrowPreference(
              title: tr('用户支持'),
              summary: tr('常见问题、联系我们'),
              onClick: () => openLink(sitePage('support.html')),
            ),
            MiuixArrowPreference(
              title: tr('隐私政策'),
              onClick: () => openLink(sitePage('privacy.html')),
            ),
            MiuixArrowPreference(
              title: tr('使用条款'),
              onClick: () => openLink(sitePage('terms.html')),
            ),
          ],
        ),
        SettingsGroup(
          title: tr('版权'),
          children: [
            MiuixBasicComponent(
              title: '© $copyrightYear $copyrightHolder',
              summary: tr('以 MIT 许可证开源'),
            ),
            MiuixArrowPreference(
              title: tr('开源许可'),
              summary: tr('本 App 用到的所有开源库的许可证全文'),
              onClick: () => showLicensePage(
                context: context,
                applicationName: 'XCAgent',
                applicationVersion: _info?.version,
                applicationLegalese: '© $copyrightYear $copyrightHolder',
                applicationIcon: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Image.asset(
                    dark
                        ? 'assets/brand/logo_dark.png'
                        : 'assets/brand/logo_light.png',
                    width: 64,
                    height: 64,
                  ),
                ),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: tr('鸣谢'),
          children: [
            for (final (name, use, license, url) in credits)
              MiuixArrowPreference(
                title: name,
                summary: '${tr(use)} · $license',
                onClick: () => openLink(url),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
          child: MiuixText(
            tr('感谢以上开源项目和它们的作者。'),
            fontSize: 12,
            textAlign: TextAlign.center,
            color: colors.onSurfaceVariantSummary,
          ),
        ),
      ],
    );
  }
}
