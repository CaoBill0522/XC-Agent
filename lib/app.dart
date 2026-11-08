import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/appearance.dart';
import 'features/home/home_shell.dart';
import 'ui/animated_miuix_theme.dart';

class AgentApp extends ConsumerWidget {
  const AgentApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    return MiuixThemeController(
      colorSchemeMode: appearance.schemeMode,
      keyColor: appearance.monet ? appearance.seed : null,
      child: Builder(
        builder: (context) {
          final theme = MiuixTheme.of(context);
          return MaterialApp(
            title: 'Agent',
            debugShowCheckedModeBanner: false,
            // 中文环境下文本选择菜单等系统控件显示中文。
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(
                seedColor: theme.colors.primary,
                brightness: theme.brightness,
              ),
              brightness: theme.brightness,
              // 所有平台统一右侧滑入（与 HyperOS / iOS 一致），并支持边缘右滑返回。
              pageTransitionsTheme: PageTransitionsTheme(
                builders: {
                  for (final p in TargetPlatform.values)
                    p: const CupertinoPageTransitionsBuilder(),
                },
              ),
              textSelectionTheme: TextSelectionThemeData(
                selectionColor: theme.colors.primary.withValues(alpha: 0.25),
                cursorColor: theme.colors.primary,
              ),
            ),
            // 切换深色模式 / 主题色时 miuix 配色平滑过渡。
            builder: (context, child) => AnimatedMiuixTheme(child: child!),
            home: const HomeShell(),
          );
        },
      ),
    );
  }
}
