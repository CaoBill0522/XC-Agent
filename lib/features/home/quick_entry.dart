import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quick_actions/quick_actions.dart';

import '../../data/providers.dart';
import '../../l10n/tr.dart';

/// 从 App 外部进入的快捷操作：主屏图标长按菜单、Siri / 快捷指令、
/// `xcagent://` 链接、桌面全局快捷键。
sealed class QuickEntry {
  const QuickEntry();

  /// 解析 `xcagent://new`、`xcagent://ask?text=…`、`xcagent://search`。
  static QuickEntry? fromUri(Uri uri) {
    if (uri.scheme != 'xcagent') return null;
    final action = uri.host.isNotEmpty
        ? uri.host
        : uri.pathSegments.firstOrNull ?? '';
    return switch (action) {
      'new' => const NewChatEntry(),
      'ask' => NewChatEntry(text: uri.queryParameters['text']),
      'search' => const SearchEntry(),
      _ => null,
    };
  }
}

/// 新建对话；[text] 预先填进输入框。
class NewChatEntry extends QuickEntry {
  const NewChatEntry({this.text});
  final String? text;
}

class SearchEntry extends QuickEntry {
  const SearchEntry();
}

/// 待处理的快捷操作，首页（窄屏 / 宽屏布局）监听并处理后清空。
class QuickEntryQueue extends Notifier<QuickEntry?> {
  @override
  QuickEntry? build() => null;

  void push(QuickEntry e) => state = e;
  void clear() => state = null;
}

final quickEntryProvider = NotifierProvider<QuickEntryQueue, QuickEntry?>(
  QuickEntryQueue.new,
);

/// 桌面全局快捷键（⌥ Space / Alt + Space）是否开启。
const hotkeyPrefKey = 'global_hotkey';

const _quickChannel = MethodChannel('cn.oxoz.agent/quick');

bool get desktopHotkeySupported => Platform.isMacOS || Platform.isWindows;

Future<void> setGlobalHotkey(bool on) async {
  if (!desktopHotkeySupported) return;
  try {
    await _quickChannel.invokeMethod('setHotkey', {'enabled': on});
  } on MissingPluginException {
    // 原生端没有实现（如测试环境）。
  } on PlatformException {
    // 快捷键已被其它 App 占用。
  }
}

/// 包在首页外面：注册各种入口，把收到的操作放进 [quickEntryProvider]。
class QuickEntryHost extends ConsumerStatefulWidget {
  const QuickEntryHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<QuickEntryHost> createState() => _QuickEntryHostState();
}

class _QuickEntryHostState extends ConsumerState<QuickEntryHost> {
  StreamSubscription<Uri>? _links;

  void _push(QuickEntry e) => ref.read(quickEntryProvider.notifier).push(e);

  @override
  void initState() {
    super.initState();
    _setUp();
  }

  Future<void> _setUp() async {
    // 单元测试里没有这些原生通道（事件通道的报错无法捕获）。
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    // 原生端（Siri / 快捷指令、桌面快捷键）调过来。
    _quickChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'ask':
          final text = (call.arguments as Map?)?['text'] as String?;
          _push(NewChatEntry(text: text));
        case 'hotkey':
          _push(const NewChatEntry());
      }
      return null;
    });
    try {
      // App 还没启动时由 Siri 打开：取出启动前收到的那一次。
      final pending = await _quickChannel.invokeMapMethod<String, Object?>(
        'takePending',
      );
      if (pending != null) {
        _push(NewChatEntry(text: pending['text'] as String?));
      }
    } on MissingPluginException {
      // 没有原生实现的平台。
    } on PlatformException {
      // 同上。
    }

    if (Platform.isIOS || Platform.isAndroid) {
      const actions = QuickActions();
      await actions.initialize((type) {
        switch (type) {
          case 'new':
            _push(const NewChatEntry());
          case 'search':
            _push(SearchEntry());
        }
      });
      await actions.setShortcutItems([
        ShortcutItem(type: 'new', localizedTitle: tr('新对话')),
        ShortcutItem(type: 'search', localizedTitle: tr('搜索对话')),
      ]);
    }

    if (!Platform.isWindows && !Platform.isLinux) {
      final links = AppLinks();
      _links = links.uriLinkStream.listen((uri) {
        if (QuickEntry.fromUri(uri) case final e?) _push(e);
      });
    }

    if (desktopHotkeySupported) {
      bool on;
      try {
        on = ref.read(prefsProvider).getBool(hotkeyPrefKey) ?? true;
      } catch (_) {
        on = false;
      }
      await setGlobalHotkey(on);
    }
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 设置页里的全局快捷键开关（仅 macOS / Windows）。
class HotkeyPreference extends ConsumerStatefulWidget {
  const HotkeyPreference({super.key});

  @override
  ConsumerState<HotkeyPreference> createState() => _HotkeyPreferenceState();
}

class _HotkeyPreferenceState extends ConsumerState<HotkeyPreference> {
  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(prefsProvider);
    final on = prefs.getBool(hotkeyPrefKey) ?? true;
    final keys = Platform.isMacOS ? '⌥ Space' : 'Alt + Space';
    return MiuixSwitchPreference(
      title: tr('全局快捷键'),
      summary: trArgs('在任何地方按 {0} 呼出 XCAgent 并新建对话', [keys]),
      value: on,
      onChanged: (v) async {
        await prefs.setBool(hotkeyPrefKey, v);
        await setGlobalHotkey(v);
        if (mounted) setState(() {});
      },
    );
  }
}
