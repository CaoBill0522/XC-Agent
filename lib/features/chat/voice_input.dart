import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../ui/app_icons.dart';
import '../../ui/motion.dart';

/// 系统语音识别（iOS / macOS：Speech 框架；Android：系统识别服务；
/// Windows：系统语音识别）。全局只有一个实例。
class VoiceRecognizer extends ChangeNotifier {
  VoiceRecognizer._();
  static final instance = VoiceRecognizer._();

  final _stt = SpeechToText();
  bool _ready = false;

  /// 当前识别出的文字（边说边更新）。
  String text = '';

  /// 归一化后的音量 0~1，用来画波形。
  double level = 0;
  double _minDb = double.infinity;
  double _maxDb = double.negativeInfinity;

  Completer<void>? _final;
  String? error;

  Future<bool> _init() async {
    if (_ready) return true;
    try {
      _ready = await _stt.initialize(
        onError: (e) {
          error = e.errorMsg;
          _final?.complete();
          _final = null;
        },
        onStatus: (s) {
          if (s == SpeechToText.doneStatus) {
            _final?.complete();
            _final = null;
          }
        },
      );
    } catch (e) {
      error = '$e';
      _ready = false;
    }
    return _ready;
  }

  /// 开始听写。没有权限或设备不支持时返回 false。
  Future<bool> start() async {
    error = null;
    text = '';
    level = 0;
    _minDb = double.infinity;
    _maxDb = double.negativeInfinity;
    if (!await _init()) return false;
    try {
      await _stt.listen(
        onResult: (r) {
          text = r.recognizedWords;
          notifyListeners();
          if (r.finalResult) {
            _final?.complete();
            _final = null;
          }
        },
        onSoundLevelChange: _onLevel,
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          autoPunctuation: true,
          // 按住说话：由松手结束，不因停顿自动结束。
          pauseFor: const Duration(seconds: 30),
          listenFor: const Duration(seconds: 90),
        ),
      );
    } catch (e) {
      error = '$e';
      return false;
    }
    notifyListeners();
    return true;
  }

  void _onLevel(double db) {
    // 各平台音量单位不一样（Android 约 -2~10，iOS 是分贝），按本次见过的范围归一化。
    _minDb = math.min(_minDb, db);
    _maxDb = math.max(_maxDb, db);
    final span = _maxDb - _minDb;
    level = span < 1 ? 0 : ((db - _minDb) / span).clamp(0, 1);
    notifyListeners();
  }

  /// 结束并等最终结果（最多等 1.5 秒），返回识别出的文字。
  Future<String> finish() async {
    if (!_stt.isListening) return text.trim();
    final done = _final = Completer<void>();
    await _stt.stop();
    await done.future.timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () {},
    );
    _final = null;
    return text.trim();
  }

  Future<void> cancel() async {
    _final = null;
    await _stt.cancel();
    text = '';
    notifyListeners();
  }
}

/// 松手时手指所在的区域。
enum VoiceZone { send, cancel, edit }

/// 按住说话：盖在空输入框上，按住开始录音，松手发送；
/// 上滑到左边「取消」放弃，上滑到右边「转文字」把文字放进输入框再改。
/// 轻点则正常聚焦输入框。
class HoldToTalk extends StatefulWidget {
  const HoldToTalk({
    super.key,
    required this.onTap,
    required this.onSend,
    required this.onEdit,
    required this.onError,
  });

  final VoidCallback onTap;
  final ValueChanged<String> onSend;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onError;

  @override
  State<HoldToTalk> createState() => _HoldToTalkState();
}

class _HoldToTalkState extends State<HoldToTalk> {
  final _voice = VoiceRecognizer.instance;
  OverlayEntry? _hud;
  final _zone = ValueNotifier(VoiceZone.send);
  bool _starting = false;
  bool _released = false;

  @override
  void dispose() {
    _removeHud();
    _zone.dispose();
    super.dispose();
  }

  void _removeHud() {
    _hud?.remove();
    _hud = null;
  }

  Future<void> _start(LongPressStartDetails d) async {
    if (_starting || _hud != null) return;
    _starting = true;
    _released = false;
    _zone.value = VoiceZone.send;
    HapticFeedback.mediumImpact();
    _hud = OverlayEntry(
      builder: (_) => _VoiceHud(voice: _voice, zone: _zone),
    );
    Overlay.of(context, rootOverlay: true).insert(_hud!);
    final ok = await _voice.start();
    _starting = false;
    if (!ok) {
      _removeHud();
      widget.onError('无法使用语音输入：请在系统设置里允许麦克风和语音识别');
      return;
    }
    // 识别器准备期间已经松手：直接按松手处理。
    if (_released) await _end();
  }

  void _move(LongPressMoveUpdateDetails d) {
    final size = MediaQuery.sizeOf(context);
    final box = context.findRenderObject() as RenderBox?;
    final top = box?.localToGlobal(Offset.zero).dy ?? size.height;
    final p = d.globalPosition;
    final next = p.dy > top - 72
        ? VoiceZone.send
        : p.dx < size.width / 2
        ? VoiceZone.cancel
        : VoiceZone.edit;
    if (next != _zone.value) {
      HapticFeedback.selectionClick();
      _zone.value = next;
    }
  }

  Future<void> _end() async {
    _released = true;
    if (_starting || _hud == null) return;
    final zone = _zone.value;
    if (zone == VoiceZone.cancel) {
      await _voice.cancel();
      _removeHud();
      return;
    }
    final text = await _voice.finish();
    _removeHud();
    if (text.isEmpty) {
      widget.onError('没有听清，请再说一次');
    } else if (zone == VoiceZone.edit) {
      widget.onEdit(text);
    } else {
      widget.onSend(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              TapGestureRecognizer.new,
              (r) => r.onTap = widget.onTap,
            ),
        // 比系统默认的 500ms 更快进入录音，接近微信的手感。
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: const Duration(milliseconds: 250),
              ),
              (r) => r
                ..onLongPressStart = _start
                ..onLongPressMoveUpdate = _move
                ..onLongPressEnd = ((_) => _end())
                ..onLongPressCancel = _end,
            ),
      },
    );
  }
}

/// 录音时的全屏提示：识别出的文字、音量波形、取消 / 转文字 两个区域。
class _VoiceHud extends StatelessWidget {
  const _VoiceHud({required this.voice, required this.zone});

  final VoiceRecognizer voice;
  final ValueListenable<VoiceZone> zone;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return IgnorePointer(
      child: AppearIn(
        child: Material(
          type: MaterialType.transparency,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.55),
            child: ValueListenableBuilder(
              valueListenable: zone,
              builder: (context, z, _) => Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // 识别出的文字气泡。
                  ListenableBuilder(
                    listenable: voice,
                    builder: (context, _) => AnimatedContainer(
                      duration: Motion.fast,
                      margin: const EdgeInsets.symmetric(horizontal: 32),
                      padding: const EdgeInsets.all(16),
                      constraints: const BoxConstraints(
                        minWidth: 160,
                        maxWidth: 520,
                      ),
                      decoration: ShapeDecoration(
                        color: z == VoiceZone.cancel
                            ? colors.error
                            : colors.primary,
                        shape: const MiuixSquircleBorder(cornerRadius: 18),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (voice.text.isNotEmpty) ...[
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 220),
                              child: SingleChildScrollView(
                                reverse: true,
                                child: MiuixText(
                                  voice.text,
                                  fontSize: 16,
                                  color: colors.onPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          _Waveform(
                            level: voice.level,
                            color: colors.onPrimary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _ZoneButton(
                          icon: AppIcons.close,
                          label: '取消',
                          active: z == VoiceZone.cancel,
                          activeColor: colors.error,
                        ),
                        _ZoneButton(
                          icon: AppIcons.edit,
                          label: '转文字',
                          active: z == VoiceZone.edit,
                          activeColor: colors.primary,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  // 底部「松开发送」区域（手指所在处）。
                  AnimatedContainer(
                    duration: Motion.fast,
                    height: 110 + bottom,
                    width: double.infinity,
                    padding: EdgeInsets.only(bottom: bottom),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: z == VoiceZone.send
                          ? Colors.white.withValues(alpha: 0.92)
                          : Colors.white.withValues(alpha: 0.18),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.elliptical(400, 60),
                      ),
                    ),
                    child: MiuixText(
                      switch (z) {
                        VoiceZone.send => '松开 发送',
                        VoiceZone.cancel => '松开 取消',
                        VoiceZone.edit => '松开 转为文字',
                      },
                      fontSize: 15,
                      color: z == VoiceZone.send
                          ? Colors.black87
                          : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoneButton extends StatelessWidget {
  const _ZoneButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.activeColor,
  });

  final MiuixVectorIcon icon;
  final String label;
  final bool active;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedScale(
          scale: active ? 1.2 : 1,
          duration: Motion.fast,
          curve: Motion.curve,
          child: AnimatedContainer(
            duration: Motion.fast,
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? activeColor : Colors.white.withValues(alpha: 0.2),
            ),
            child: MiuixIcon(vector: icon, size: 26, tint: Colors.white),
          ),
        ),
        const SizedBox(height: 10),
        MiuixText(label, fontSize: 13, color: Colors.white),
      ],
    );
  }
}

/// 简单的音量波形：一排竖条，高度随音量起伏。
class _Waveform extends StatefulWidget {
  const _Waveform({required this.level, required this.color});

  final double level;
  final Color color;

  @override
  State<_Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<_Waveform>
    with SingleTickerProviderStateMixin {
  late final _tick = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const bars = 21;
    return SizedBox(
      height: 28,
      child: AnimatedBuilder(
        animation: _tick,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < bars; i++)
              Container(
                width: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                height:
                    4 +
                    22 *
                        (0.25 + 0.75 * widget.level) *
                        (0.5 +
                            0.5 *
                                math
                                    .sin(_tick.value * 2 * math.pi + i * 0.7)
                                    .abs()) *
                        (1 - (i - bars ~/ 2).abs() / bars),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
