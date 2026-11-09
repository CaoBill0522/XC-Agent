import 'dart:io';

import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/core/chat/conversation_mode.dart';
import 'package:agent/core/chat/conversation_options.dart';
import 'package:agent/core/models/capabilities.dart';
import 'package:agent/core/routing/model_router.dart';
import 'package:agent/data/appearance.dart';
import 'package:agent/data/chat_service.dart';
import 'package:agent/data/tool_service.dart';
import 'package:agent/data/voice_service.dart';
import 'package:agent/features/lock/app_lock.dart';
import 'package:agent/l10n/en.dart';
import 'package:agent/l10n/tr.dart';
import 'package:flutter_test/flutter_test.dart';

final _cjk = RegExp(r'[一-鿿]');

/// 源码里单引号字符串的转义还原成运行时的值。
String _unescape(String s) => s.replaceAllMapped(
  RegExp(r'\\(.)'),
  (m) => switch (m[1]) {
    'n' => '\n',
    't' => '\t',
    _ => m[1]!,
  },
);

void main() {
  tearDown(() => L10n.use(AppLanguage.zh));

  test('源码里每个 tr / trArgs 的中文都有英文译文', () {
    final call = RegExp(r"\b(?:tr|trArgs)\(\s*'((?:[^'\\]|\\.)*)'");
    final missing = <String>{};
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File ||
          !f.path.endsWith('.dart') ||
          f.path.contains('/l10n/')) {
        continue;
      }
      for (final m in call.allMatches(f.readAsStringSync())) {
        final key = _unescape(m[1]!);
        if (_cjk.hasMatch(key) && !enStrings.containsKey(key)) {
          missing.add('${f.path}: $key');
        }
      }
    }
    expect(missing, isEmpty, reason: '运行 python3 tool/l10n/keys.py 补上译文');
  });

  test('译文没有中文，占位符和原文一致', () {
    final ph = RegExp(r'\{\d+\}');
    for (final MapEntry(:key, :value) in enStrings.entries) {
      expect(_cjk.hasMatch(value), isFalse, reason: value);
      expect(
        ph.allMatches(value).map((m) => m[0]).toSet(),
        ph.allMatches(key).map((m) => m[0]).toSet(),
        reason: key,
      );
    }
  });

  test('英文界面：枚举名称、提示常量全部有译文', () {
    L10n.use(AppLanguage.en);
    final labels = [
      for (final m in ConversationMode.values) ...[m.label, m.description],
      for (final c in ModelCapability.values) c.label,
      for (final r in RouteStrategy.values) ...[r.label, r.description],
      for (final e in ReasoningEffort.values) e.label,
      for (final t in ThemeModeSetting.values) t.label,
      for (final b in BuiltinTool.values) b.label,
      for (final v in VoiceEngine.values) v.label,
      for (final (_, l) in AppLockSettings.delays) tr(l),
      for (final (_, l) in ConversationOptions.imageRatios) tr(l),
      for (final (n, _) in seedColors) tr(n),
      tr(ChatService.noSearchNotice),
      tr(ChatService.noToolsNotice),
      ChatService.displayTitle(ChatService.defaultTitle),
      ChatService.displayTitle(ChatService.followUpTitle('什么是熵')),
    ];
    for (final l in labels) {
      // 追问标题里用户选中的原文本来就是中文。
      expect(_cjk.hasMatch(l.replaceAll('什么是熵', '')), isFalse, reason: l);
    }
    expect(trArgs('{0} 个渠道', [3]), '3 channels');
    expect(ChatService.displayTitle('追问：什么是熵'), 'Follow-up: 什么是熵');
  });

  test('中文界面：原样显示', () {
    L10n.use(AppLanguage.zh);
    expect(tr('设置'), '设置');
    expect(trArgs('{0} 个渠道', [3]), '3 个渠道');
    expect(ConversationMode.judge.label, '裁判评分');
  });
}
