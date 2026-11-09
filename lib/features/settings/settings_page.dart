import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/settings_widgets.dart';
import '../agents/agents_page.dart';
import '../channels/channels_page.dart';
import '../models/models_page.dart';
import '../home/quick_entry.dart';
import '../lock/app_lock.dart';
import 'appearance_page.dart';
import 'language_preference.dart';
import 'data_page.dart';
import 'prompts_page.dart';
import 'tools_page.dart';
import 'usage_page.dart';
import '../../l10n/tr.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final channels = ref.watch(channelsProvider).value ?? const [];
    final models = ref.watch(modelsProvider).value ?? const [];
    final agents = ref.watch(agentsProvider).value ?? const [];

    Widget icon(MiuixVectorIcon v) => Padding(
      padding: const EdgeInsets.only(right: 14),
      child: MiuixIcon(vector: v, size: 24, tint: colors.primary),
    );
    void push(Widget page) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

    return SettingsScaffold(
      title: tr('设置'),
      showBack: !embedded,
      children: [
        SettingsGroup(
          title: tr('接入'),
          children: [
            MiuixArrowPreference(
              title: tr('渠道'),
              summary: channels.isEmpty
                  ? tr('添加 API Key，从云端拉取模型')
                  : trArgs('{0} 个渠道', [channels.length]),
              startAction: icon(AppIcons.layers),
              onClick: () => push(const ChannelsPage()),
            ),
            MiuixArrowPreference(
              title: tr('模型'),
              summary: models.isEmpty
                  ? tr('能力标签、多渠道轮询')
                  : trArgs('{0} 个模型', [models.length]),
              startAction: icon(AppIcons.community),
              onClick: () => push(const ModelsPage()),
            ),
            MiuixArrowPreference(
              title: tr('提示词'),
              summary: tr('常用提问方式，在输入框里打 / 调出'),
              startAction: icon(AppIcons.notes),
              onClick: () => push(const PromptsPage()),
            ),
            MiuixArrowPreference(
              title: tr('工具'),
              summary: tr('读取网页、计算器、MCP 服务器'),
              startAction: icon(AppIcons.tools),
              onClick: () => push(const ToolsPage()),
            ),
            MiuixArrowPreference(
              title: tr('助手'),
              summary: agents.isEmpty
                  ? tr('系统提示词与参数预设')
                  : trArgs('{0} 个助手', [agents.length]),
              startAction: icon(AppIcons.edit),
              onClick: () => push(const AgentsPage()),
            ),
          ],
        ),
        SettingsGroup(
          title: tr('通用'),
          children: [
            MiuixArrowPreference(
              title: tr('用量统计'),
              summary: tr('请求次数和 token 用量，按模型、渠道汇总'),
              startAction: icon(AppIcons.filter),
              onClick: () => push(const UsagePage()),
            ),
            MiuixArrowPreference(
              title: tr('外观'),
              summary: tr('深色模式、主题色'),
              startAction: icon(AppIcons.theme),
              onClick: () => push(const AppearancePage()),
            ),
            const LanguagePreference(),
            const AppLockPreference(),
            if (desktopHotkeySupported) const HotkeyPreference(),
            MiuixArrowPreference(
              title: tr('数据'),
              summary: tr('配置导入导出、清空对话'),
              startAction: icon(AppIcons.backup),
              onClick: () => push(const DataPage()),
            ),
            MiuixArrowPreference(
              title: tr('关于'),
              summary: 'cn.oxoz.agent',
              startAction: icon(AppIcons.info),
              onClick: () => showAppDialog<void>(
                context,
                title: 'XCAgent',
                summary: tr(
                  'cn.oxoz.agent\n\n支持 OpenAI / Anthropic 格式的多模型 AI 客户端。\n多渠道轮询 · 多 Agent 并问 · 识图与生图 · 原生联网搜索。\n\n数据默认只保存在本机（可选 iCloud 同步）。界面基于 flutter_miuix（Apache-2.0）。',
                ),
                content: (ctx, close) => Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: MiuixTextButton(
                    tr('好'),
                    onPressed: close,
                    colors: MiuixButtonDefaults.buttonColorsPrimary(ctx),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
