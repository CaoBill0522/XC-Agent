import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/provider_preset.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/settings_widgets.dart';
import 'channel_edit_page.dart';
import '../../l10n/tr.dart';

/// 渠道列表。
class ChannelsPage extends ConsumerWidget {
  const ChannelsPage({super.key});

  void _add(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const PresetPickerPage()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final channels = ref.watch(channelsProvider);
    final presets =
        ref.watch(presetsProvider).value ?? const <ProviderPreset>[];
    String presetName(String id) =>
        presets.where((p) => p.id == id).firstOrNull?.name ?? id;

    return SettingsScaffold(
      title: tr('渠道'),
      actions: [
        AppIconButton(icon: AppIcons.add, onPressed: () => _add(context)),
      ],
      children: [
        ...channels.when(
          loading: () => [const SizedBox.shrink()],
          error: (e, _) => [
            Center(child: MiuixText(trArgs('加载失败：{0}', [e]))),
          ],
          data: (items) => items.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 64,
                      horizontal: 32,
                    ),
                    child: Column(
                      children: [
                        MiuixIcon(
                          vector: AppIcons.layers,
                          size: 44,
                          tint: colors.onSurfaceVariantSummary,
                        ),
                        const SizedBox(height: 12),
                        MiuixText(
                          tr('还没有渠道\n添加 API Key 后即可拉取模型开始聊天'),
                          textAlign: TextAlign.center,
                          color: colors.onSurfaceVariantSummary,
                        ),
                        const SizedBox(height: 24),
                        PrimaryButton(
                          text: tr('添加渠道'),
                          onPressed: () => _add(context),
                        ),
                      ],
                    ),
                  ),
                ]
              : [
                  SettingsGroup(
                    children: [
                      for (final s in items)
                        MiuixArrowPreference(
                          title: s.channel.name,
                          titleColor: s.channel.enabled
                              ? null
                              : MiuixBasicComponentColors(
                                  color: colors.onSurfaceVariantSummary,
                                  disabledColor: colors.disabledOnSurface,
                                ),
                          summary: [
                            if (presetName(s.channel.presetId) !=
                                s.channel.name)
                              presetName(s.channel.presetId),
                            s.protocol.label,
                            trArgs('{0} 个模型', [s.modelCount]),
                            if (!s.channel.enabled) tr('已停用'),
                          ].join(' · '),
                          onClick: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  ChannelEditPage(channelId: s.channel.id),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
        ),
      ],
    );
  }
}

/// 选择厂商预设，然后进入渠道编辑。
class PresetPickerPage extends ConsumerWidget {
  const PresetPickerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets = ref.watch(presetsProvider);
    return SettingsScaffold(
      title: tr('选择厂商'),
      children: [
        ...presets.when(
          loading: () => [const SizedBox.shrink()],
          error: (e, _) => [
            Center(child: MiuixText(trArgs('预设加载失败：{0}', [e]))),
          ],
          data: (list) => [
            SettingsGroup(
              children: [
                for (final p in list)
                  MiuixArrowPreference(
                    title: p.name,
                    summary: p.isCustom
                        ? tr('任意 OpenAI / Anthropic 兼容地址')
                        : p.endpoints.map((e) => e.protocol.label).join(' / '),
                    onClick: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => ChannelEditPage(preset: p),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
