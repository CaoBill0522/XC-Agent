import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/language.dart';
import '../../l10n/tr.dart';
import '../../ui/app_icons.dart';

/// 设置页里的「语言 / Language」。
class LanguagePreference extends ConsumerWidget {
  const LanguagePreference({super.key});

  /// 选项名不翻译：中文用户和英文用户都要认得出来。
  static String labelOf(AppLanguage l) => switch (l) {
    AppLanguage.system => tr('跟随系统'),
    AppLanguage.zh => '简体中文',
    AppLanguage.en => 'English',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final current = ref.watch(languageProvider);
    return MiuixOverlayDropdownPreference(
      title: L10n.isEn ? 'Language / 语言' : '语言 / Language',
      startAction: Padding(
        padding: const EdgeInsets.only(right: 14),
        child: MiuixIcon(
          vector: AppIcons.translate,
          size: 24,
          tint: colors.primary,
        ),
      ),
      items: [for (final l in AppLanguage.values) labelOf(l)],
      selectedIndex: AppLanguage.values.indexOf(current),
      onSelectedIndexChange: (i) =>
          ref.read(languageProvider.notifier).set(AppLanguage.values[i]),
    );
  }
}
