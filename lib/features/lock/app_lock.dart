import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/layout.dart';
import '../../ui/motion.dart';
import '../../ui/settings_widgets.dart';
import '../../l10n/tr.dart';

/// 应用锁设置：开启后打开 App（或离开超过 [delay] 后回来）需要 Face ID /
/// 指纹 / 系统密码解锁；切到后台时遮住画面，多任务界面里看不到聊天内容。
class AppLockSettings {
  const AppLockSettings({this.enabled = false, this.delay = Duration.zero});

  final bool enabled;
  final Duration delay;

  /// 离开多久后回来需要重新解锁。
  static const delays = [
    (Duration.zero, '立即'),
    (Duration(minutes: 1), '1 分钟后'),
    (Duration(minutes: 5), '5 分钟后'),
    (Duration(minutes: 30), '30 分钟后'),
  ];
}

class AppLockNotifier extends Notifier<AppLockSettings> {
  static const _enabledKey = 'app_lock';
  static const _delayKey = 'app_lock_delay';

  @override
  AppLockSettings build() {
    final prefs = ref.read(prefsProvider);
    return AppLockSettings(
      enabled: prefs.getBool(_enabledKey) ?? false,
      delay: Duration(seconds: prefs.getInt(_delayKey) ?? 0),
    );
  }

  void setEnabled(bool on) {
    ref.read(prefsProvider).setBool(_enabledKey, on);
    state = AppLockSettings(enabled: on, delay: state.delay);
  }

  void setDelay(Duration d) {
    ref.read(prefsProvider).setInt(_delayKey, d.inSeconds);
    state = AppLockSettings(enabled: state.enabled, delay: d);
  }
}

final appLockProvider = NotifierProvider<AppLockNotifier, AppLockSettings>(
  AppLockNotifier.new,
);

/// 系统身份验证（Face ID / 触控 ID / 指纹 / Windows Hello，失败时可用设备密码）。
abstract final class DeviceAuth {
  static final _auth = LocalAuthentication();

  static Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}

/// 包在整个 App 外面：锁定时盖上解锁页，进入后台时盖上遮罩。
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  late bool _locked = ref.read(appLockProvider).enabled;
  bool _obscured = false;
  bool _authing = false;
  DateTime? _leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final settings = ref.read(appLockProvider);
    if (!settings.enabled) {
      if (_obscured || _locked) {
        setState(() => _obscured = _locked = false);
      }
      return;
    }
    switch (state) {
      case AppLifecycleState.inactive:
        // 手机上是多任务界面 / 控制中心 / Face ID 弹窗：遮住内容。
        // 桌面上窗口失去焦点就是 inactive，不遮。
        if (!isDesktopPlatform) setState(() => _obscured = true);
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _leftAt ??= DateTime.now();
        setState(() => _obscured = true);
      case AppLifecycleState.resumed:
        final left = _leftAt;
        _leftAt = null;
        final relock =
            left != null && DateTime.now().difference(left) >= settings.delay;
        setState(() {
          _obscured = false;
          if (relock) _locked = true;
        });
        if (_locked) _unlock();
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _unlock() async {
    if (_authing || !mounted) return;
    // 设备没有设置任何解锁方式时不锁，免得把用户锁在外面。
    if (!await DeviceAuth.available()) {
      if (mounted) setState(() => _locked = false);
      return;
    }
    _authing = true;
    final ok = await DeviceAuth.authenticate(tr('解锁 XCAgent'));
    _authing = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    // 设置里关掉应用锁时立即解除。
    ref.listen(appLockProvider, (_, next) {
      if (!next.enabled && (_locked || _obscured)) {
        setState(() => _locked = _obscured = false);
      }
    });
    final cover = _locked || _obscured;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 锁定时下面的内容不接收焦点和点击。
        ExcludeFocus(
          excluding: _locked,
          child: IgnorePointer(ignoring: _locked, child: widget.child),
        ),
        IgnorePointer(
          ignoring: !cover,
          child: AnimatedOpacity(
            opacity: cover ? 1 : 0,
            duration: _locked || _obscured ? Duration.zero : Motion.medium,
            child: _LockScreen(locked: _locked, onUnlock: _unlock),
          ),
        ),
      ],
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.locked, required this.onUnlock});

  final bool locked;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return ColoredBox(
      color: colors.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiuixIcon(vector: AppIcons.lock, size: 48, tint: colors.primary),
            const SizedBox(height: 16),
            MiuixText(
              'XCAgent',
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
            const SizedBox(height: 32),
            AnimatedOpacity(
              opacity: locked ? 1 : 0,
              duration: Motion.fast,
              child: SizedBox(
                width: 200,
                child: PrimaryButton(text: tr('解锁'), onPressed: onUnlock),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置页里的「应用锁」开关；开启后多一项「自动锁定」时间。
class AppLockPreference extends ConsumerWidget {
  const AppLockPreference({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final s = ref.watch(appLockProvider);
    final n = ref.read(appLockProvider.notifier);
    final delayIndex = AppLockSettings.delays.indexWhere(
      (d) => d.$1 == s.delay,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MiuixSwitchPreference(
          title: tr('应用锁'),
          summary: tr('打开时需要 Face ID、指纹或设备密码'),
          startAction: Padding(
            padding: const EdgeInsets.only(right: 14),
            child: MiuixIcon(
              vector: AppIcons.lock,
              size: 24,
              tint: colors.primary,
            ),
          ),
          value: s.enabled,
          onChanged: (on) async {
            if (!on) {
              n.setEnabled(false);
              return;
            }
            if (!await DeviceAuth.available()) {
              if (context.mounted) {
                await showConfirm(
                  context,
                  title: tr('无法开启应用锁'),
                  message: tr('这台设备没有设置锁屏密码或生物识别，请先在系统设置里开启。'),
                  confirmText: tr('好'),
                );
              }
              return;
            }
            // 先验证一次，确认能解锁再开启。
            if (await DeviceAuth.authenticate(tr('开启应用锁'))) n.setEnabled(true);
          },
        ),
        AnimatedSize(
          duration: Motion.medium,
          curve: Motion.curve,
          child: s.enabled
              ? MiuixOverlayDropdownPreference(
                  title: tr('自动锁定'),
                  summary: tr('离开 App 多久后需要重新解锁'),
                  items: [for (final d in AppLockSettings.delays) tr(d.$2)],
                  selectedIndex: delayIndex < 0 ? 0 : delayIndex,
                  onSelectedIndexChange: (i) =>
                      n.setDelay(AppLockSettings.delays[i].$1),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
