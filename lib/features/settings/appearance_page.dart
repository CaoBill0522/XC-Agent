import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/motion.dart';
import '../../data/appearance.dart';
import '../../ui/settings_widgets.dart';

class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(appearanceProvider);
    final n = ref.read(appearanceProvider.notifier);
    final colors = MiuixTheme.of(context).colors;

    return SettingsScaffold(
      title: '外观',
      children: [
        SettingsGroup(
          children: [
            MiuixOverlayDropdownPreference(
              title: '深色模式',
              items: [for (final m in ThemeModeSetting.values) m.label],
              selectedIndex: a.mode.index,
              onSelectedIndexChange: (i) =>
                  n.setMode(ThemeModeSetting.values[i]),
            ),
            MiuixSwitchPreference(
              title: '动态取色 (Monet)',
              summary: '用主题色生成整套配色',
              value: a.monet,
              onChanged: n.setMonet,
            ),
          ],
        ),
        if (a.monet)
          SettingsGroup(
            title: '主题色',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (final (name, color) in seedColors)
                      Tap(
                        onTap: () => n.setSeed(color),
                        child: Column(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: color == null
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
                                color: color,
                                border: a.seed == color
                                    ? Border.all(
                                        color: colors.onSurface,
                                        width: 2.5,
                                      )
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 4),
                            MiuixText(
                              name,
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
