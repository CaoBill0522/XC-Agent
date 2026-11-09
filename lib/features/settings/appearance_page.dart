import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/motion.dart';
import '../../data/appearance.dart';
import '../../ui/settings_widgets.dart';
import '../../l10n/tr.dart';

class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(appearanceProvider);
    final n = ref.read(appearanceProvider.notifier);
    final colors = MiuixTheme.of(context).colors;

    return SettingsScaffold(
      title: tr('外观'),
      children: [
        SettingsGroup(
          children: [
            MiuixOverlayDropdownPreference(
              title: tr('深色模式'),
              items: [for (final m in ThemeModeSetting.values) m.label],
              selectedIndex: a.mode.index,
              onSelectedIndexChange: (i) =>
                  n.setMode(ThemeModeSetting.values[i]),
            ),
            if (wallpaperColorSupported)
              MiuixSwitchPreference(
                title: tr('动态取色 (Monet)'),
                summary: tr('用主题色生成整套配色'),
                value: a.monet,
                onChanged: n.setMonet,
              ),
          ],
        ),
        if (a.monet || !wallpaperColorSupported)
          SettingsGroup(
            title: tr('主题色'),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (final (name, color) in seedColors)
                      // 「默认」就是蓝色，不再重复列出「蓝」。
                      if (wallpaperColorSupported ||
                          color != const Color(0xFF3482FF))
                        Tap(
                          onTap: () => wallpaperColorSupported
                              ? n.setSeed(color)
                              : n.setThemeColor(color),
                          child: Column(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient:
                                      color == null && wallpaperColorSupported
                                      ? const SweepGradient(
                                          colors: [
                                            Colors.red,
                                            Colors.orange,
                                            Colors.yellow,
                                            Colors.green,
                                            Colors.blue,
                                            Colors.purple,
                                            Colors.red,
                                          ],
                                        )
                                      : null,
                                  // 其它平台的第一项是「默认」：显示默认主色。
                                  color:
                                      color ??
                                      (wallpaperColorSupported
                                          ? null
                                          : const Color(0xFF3482FF)),
                                  border:
                                      (wallpaperColorSupported || a.monet
                                              ? a.seed
                                              : null) ==
                                          color
                                      ? Border.all(
                                          color: colors.onSurface,
                                          width: 2.5,
                                        )
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 4),
                              MiuixText(
                                color == null && !wallpaperColorSupported
                                    ? tr('默认')
                                    : tr(name),
                                fontSize: 11,
                                color: colors.onSurfaceVariantSummary,
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}
