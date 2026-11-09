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

/// 可选的主题种子色。null 表示「壁纸取色」（仅 Android 有效，其他平台回退默认色）。
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
    return Appearance(
      mode:
          ThemeModeSetting.values.elementAtOrNull(p.getInt(_kMode) ?? 0) ??
          ThemeModeSetting.system,
      monet: p.getBool(_kMonet) ?? false,
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

  void setSeed(Color? c) {
    final p = ref.read(prefsProvider);
    c == null ? p.remove(_kSeed) : p.setInt(_kSeed, c.toARGB32());
    state = Appearance(mode: state.mode, monet: state.monet, seed: c);
  }
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(
  AppearanceNotifier.new,
);
