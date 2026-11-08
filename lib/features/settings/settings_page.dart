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
import 'appearance_page.dart';
import 'data_page.dart';

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
      title: '设置',
      showBack: !embedded,
      children: [
        SettingsGroup(
          title: '接入',
          children: [
            MiuixArrowPreference(
              title: '渠道',
              summary: channels.isEmpty
                  ? '添加 API Key，从云端拉取模型'
                  : '${channels.length} 个渠道',
              startAction: icon(AppIcons.layers),
              onClick: () => push(const ChannelsPage()),
            ),
            MiuixArrowPreference(
              title: '模型',
              summary: models.isEmpty ? '能力标签、多渠道轮询' : '${models.length} 个模型',
              startAction: icon(AppIcons.community),
              onClick: () => push(const ModelsPage()),
            ),
            MiuixArrowPreference(
              title: '助手',
              summary: agents.isEmpty ? '系统提示词与参数预设' : '${agents.length} 个助手',
              startAction: icon(AppIcons.edit),
              onClick: () => push(const AgentsPage()),
            ),
          ],
        ),
        SettingsGroup(
          title: '通用',
          children: [
            MiuixArrowPreference(
              title: '外观',
              summary: '深色模式、主题色',
              startAction: icon(AppIcons.theme),
              onClick: () => push(const AppearancePage()),
            ),
            MiuixArrowPreference(
              title: '数据',
              summary: '配置导入导出、清空对话',
              startAction: icon(AppIcons.backup),
              onClick: () => push(const DataPage()),
            ),
            MiuixArrowPreference(
              title: '关于',
              summary: 'cn.oxoz.agent',
              startAction: icon(AppIcons.info),
              onClick: () => showAppDialog<void>(
                context,
                title: 'Agent',
                summary:
                    'cn.oxoz.agent\n\n'
                    '支持 OpenAI / Anthropic 格式的多模型 AI 客户端。\n'
                    '多渠道轮询 · 多 Agent 并问 · 识图与生图 · 原生联网搜索。\n\n'
                    '所有数据只保存在本机。界面基于 flutter_miuix（Apache-2.0）。',
                content: (ctx, close) => Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: MiuixTextButton(
                    '好',
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
