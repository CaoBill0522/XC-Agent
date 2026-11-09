import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'tr.dart';

/// 界面语言设置（跟随系统 / 中文 / English），存在偏好里。
class LanguageNotifier extends Notifier<AppLanguage> {
  static const key = 'language';

  @override
  AppLanguage build() => L10n.language;

  void set(AppLanguage language) {
    ref.read(prefsProvider).setString(key, language.id);
    L10n.use(language);
    state = language;
    L10n.rebuildAll();
  }
}

final languageProvider = NotifierProvider<LanguageNotifier, AppLanguage>(
  LanguageNotifier.new,
);
