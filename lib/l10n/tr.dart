import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import 'en.dart';

/// 界面语言。[system] 跟随系统：系统是中文时用中文，否则英文。
enum AppLanguage {
  system('system'),
  zh('zh'),
  en('en');

  const AppLanguage(this.id);
  final String id;

  static AppLanguage fromId(String? id) =>
      values.firstWhere((l) => l.id == id, orElse: () => system);
}

/// 轻量的双语方案：源码里直接写中文，用 [tr] / [trArgs] 包起来；
/// 英文界面时按中文原文去 [enStrings] 里查译文，查不到就显示原文。
///
/// 存进数据库的提示（NoticePart 等）保存中文原文，显示时再翻译，
/// 这样切换语言后旧消息里的提示也会跟着变。
abstract final class L10n {
  static AppLanguage _language = AppLanguage.zh;

  /// 测试里默认中文；App 启动时按设置调用 [use]。
  static bool isEn = false;

  static AppLanguage get language => _language;

  static void use(AppLanguage language) {
    _language = language;
    isEn = switch (language) {
      AppLanguage.zh => false,
      AppLanguage.en => true,
      AppLanguage.system =>
        PlatformDispatcher.instance.locale.languageCode != 'zh',
    };
  }

  static Locale get locale =>
      isEn ? const Locale('en') : const Locale('zh', 'CN');

  /// 切换语言后让整棵树重建（保留页面和状态）。
  static void rebuildAll() {
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  }
}

/// 翻译一段界面文字（参数是中文原文）。
String tr(String zh) => L10n.isEn ? (enStrings[zh] ?? zh) : zh;

/// 带参数的文字：原文里用 {0}、{1}… 占位。
String trArgs(String zh, List<Object?> args) {
  var s = tr(zh);
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}
