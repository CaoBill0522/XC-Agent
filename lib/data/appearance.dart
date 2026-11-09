import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import '../l10n/tr.dart';

enum ThemeModeSetting {
  system('跟随系统'),
  light('浅色'),
  dark('深色');

  const ThemeModeSetting(this._label);
  final String _label;
  String get label => tr(_label);
}

class Appearance {
  const Appearance({
    this.mode = ThemeModeSetting.system,
    this.monet = false,
    this.seed,
  });

  final ThemeModeSetting mode;

  /// 是否用 Monet 动态取色（按 [seed] 生成整套配色；Android 上 seed 为空时取壁纸色）。
  final bool monet;
  final Color? seed;

  MiuixColorSchemeMode get schemeMode => switch ((monet, mode)) {
    (false, ThemeModeSetting.system) => MiuixColorSchemeMode.system,
    (false, ThemeModeSetting.light) => MiuixColorSchemeMode.light,
    (false, ThemeModeSetting.dark) => MiuixColorSchemeMode.dark,
    (true, ThemeModeSetting.system) => MiuixColorSchemeMode.monetSystem,
    (true, ThemeModeSetting.light) => MiuixColorSchemeMode.monetLight,
    (true, ThemeModeSetting.dark) => MiuixColorSchemeMode.monetDark,
  };
}

/// 只有 Android 能读系统壁纸取色；iOS / 桌面端 miuix 会回退到固定配色，
/// 看起来像没生效，所以这些平台不提供「动态取色」开关和「壁纸取色」，只能选主题色。
bool get wallpaperColorSupported => Platform.isAndroid;

/// 可选的主题种子色。null 表示「壁纸取色」（仅 Android）。
const seedColors = <(String, Color?)>[
  ('壁纸取色', null),
  ('蓝', Color(0xFF3482FF)),
  ('青', Color(0xFF00A3A3)),
  ('绿', Color(0xFF2EAD5B)),
  ('橙', Color(0xFFFF8A00)),
  ('红', Color(0xFFE5484D)),
  ('紫', Color(0xFF7C5CFF)),
];

class AppearanceNotifier extends Notifier<Appearance> {
  static const _kMode = 'appearance_mode';
  static const _kMonet = 'appearance_monet';
  static const _kSeed = 'appearance_seed';

  @override
  Appearance build() {
    final p = ref.watch(prefsProvider);
    final seed = p.getInt(_kSeed);
    final monet = p.getBool(_kMonet) ?? false;
    return Appearance(
      mode:
          ThemeModeSetting.values.elementAtOrNull(p.getInt(_kMode) ?? 0) ??
          ThemeModeSetting.system,
      // 不支持壁纸取色的平台上，「动态取色 + 壁纸」等同于默认配色。
      monet: monet && (seed != null || wallpaperColorSupported),
      seed: seed == null ? null : Color(seed),
    );
  }

  void setMode(ThemeModeSetting m) {
    ref.read(prefsProvider).setInt(_kMode, m.index);
    state = Appearance(mode: m, monet: state.monet, seed: state.seed);
  }

  void setMonet(bool on) {
    ref.read(prefsProvider).setBool(_kMonet, on);
    state = Appearance(mode: state.mode, monet: on, seed: state.seed);
  }

  /// 只选主题色的平台用：null = 默认配色，否则按这个颜色生成整套配色。
  void setThemeColor(Color? c) {
    setSeed(c);
    setMonet(c != null);
  }

  void setSeed(Color? c) {
    final p = ref.read(prefsProvider);
    c == null ? p.remove(_kSeed) : p.setInt(_kSeed, c.toARGB32());
    state = Appearance(mode: state.mode, monet: state.monet, seed: c);
  }
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(
  AppearanceNotifier.new,
);
