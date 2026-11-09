import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../core/api/api_error.dart';
import '../../data/voice_service.dart';
import '../../ui/app_icons.dart';
import '../../ui/motion.dart';
import '../../l10n/tr.dart';

/// 语音识别，两种方式（见 [VoiceEngine]）：
/// - 系统识别（iOS / macOS：Speech 框架；Android：系统识别服务；Windows：系统语音识别），
///   边说边出字；
/// - 模型转写：录音，松手后交给 [Transcriber]，中英混说也能认对。
/// 全局只有一个实例。
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

  // ── 模型转写
  AudioRecorder? _recorder;
  Transcriber? _cloud;
  StreamSubscription<Amplitude>? _amp;
  CancelToken? _cancelToken;
  String? _path;
  DateTime _startedAt = DateTime.now();

  /// 本次是不是模型转写（松手后才出字）。
  bool get cloud => _cloud != null;

  /// 松手后正在等模型返回。
  bool transcribing = false;

  /// 识别语言跟界面语言走（中文界面 → 普通话）。不传的话 iOS 用 App 的
  /// Locale.current，很可能是英文，中文就识别不出来。
  String? _localeId;
  bool? _localeForEn;

  Future<String?> _pickLocale() async {
    final en = L10n.isEn;
    if (_localeForEn == en) return _localeId;
    _localeForEn = en;
    List<LocaleName> all;
    try {
      all = await _stt.locales();
    } catch (_) {
      all = const [];
    }
    String norm(String id) => id.replaceAll('-', '_').toLowerCase();
    final wanted = en
        ? ['en_us', 'en_gb', 'en']
        : ['zh_cn', 'zh_hans_cn', 'cmn_hans_cn', 'zh_hans', 'zh'];
    for (final w in wanted) {
      for (final l in all) {
        final id = norm(l.localeId);
        if (id == w || (w.length <= 3 && id.startsWith('${w}_'))) {
          return _localeId = l.localeId;
        }
      }
    }
    // 列表拿不到时直接指定。
    return _localeId = en ? 'en_US' : 'zh_CN';
  }

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

  /// 开始听写；传了 [cloud] 就录音、松手后用模型转写。
  /// 没有权限或设备不支持时返回 false。
  Future<bool> start({Transcriber? cloud}) async {
    error = null;
    text = '';
    level = 0;
    transcribing = false;
    _minDb = double.infinity;
    _maxDb = double.negativeInfinity;
    _cloud = cloud;
    _startedAt = DateTime.now();
    if (cloud != null) return _startRecording();
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
          localeId: await _pickLocale(),
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

  Future<bool> _startRecording() async {
    final rec = _recorder ??= AudioRecorder();
    try {
      if (!await rec.hasPermission()) return false;
      final dir = await getTemporaryDirectory();
      final path = _path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      // 16 kHz 单声道 WAV：各家转写接口都收，一分钟不到 2 MB。
      await rec.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      _amp = rec
          .onAmplitudeChanged(const Duration(milliseconds: 80))
          .listen((a) => _onLevel(a.current));
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

  /// 结束并等最终结果，返回识别出的文字。系统识别最多等 1.5 秒；
  /// 模型转写要等接口返回，失败时抛出异常。
  Future<String> finish() async {
    if (_cloud != null) return _finishCloud(_cloud!);
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

  Future<String> _finishCloud(Transcriber cloud) async {
    await _amp?.cancel();
    _amp = null;
    final path = await _recorder?.stop() ?? _path;
    level = 0;
    // 太短或几乎没声音：不上传。Whisper 类模型对静音会「脑补」出
    // 「谢谢观看」之类的句子。
    final short =
        DateTime.now().difference(_startedAt) <
        const Duration(milliseconds: 600);
    if (path == null || short || _maxDb < -50) {
      _deleteRecording(path);
      return '';
    }
    transcribing = true;
    notifyListeners();
    try {
      text = await cloud.transcribe(path, cancel: _cancelToken = CancelToken());
      return text.trim();
    } finally {
      _cancelToken = null;
      transcribing = false;
      _deleteRecording(path);
      notifyListeners();
    }
  }

  void _deleteRecording(String? path) {
    if (path == null) return;
    File(path).delete().catchError((_) => File(path));
  }

  Future<void> cancel() async {
    _final = null;
    if (_cloud != null) {
      _cancelToken?.cancel();
      await _amp?.cancel();
      _amp = null;
      // 取消录音会顺带删掉文件。
      await _recorder?.cancel();
    } else {
      await _stt.cancel();
    }
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
    this.transcriber,
  });

  /// 设置里选了模型转写时返回转写器；为空或返回 null 时用系统识别。
  final Future<Transcriber?> Function()? transcriber;

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
    Transcriber? cloud;
    try {
      cloud = await widget.transcriber?.call();
    } catch (_) {}
    final ok = await _voice.start(cloud: cloud);
    _starting = false;
    if (!ok) {
      _removeHud();
      widget.onError(
        cloud != null
            ? tr('无法录音：请在系统设置里允许使用麦克风')
            : tr('无法使用语音输入：请在系统设置里允许麦克风和语音识别'),
      );
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
    final String text;
    try {
      text = await _voice.finish();
    } catch (e) {
      _removeHud();
      if (e is DioException && CancelToken.isCancel(e)) return;
      widget.onError(
        trArgs('语音转写失败：{0}', [e is ApiException ? e.message : '$e']),
      );
      return;
    }
    _removeHud();
    if (!mounted) return;
    if (text.isEmpty) {
      widget.onError(tr('没有听清，请再说一次'));
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
                          ] else if (voice.cloud) ...[
                            // 模型转写松手后才出字：先告诉用户在干什么。
                            MiuixText(
                              voice.transcribing
                                  ? tr('正在识别…')
                                  : tr('正在录音，松手后识别'),
                              fontSize: 15,
                              color: colors.onPrimary.withValues(alpha: 0.85),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (voice.transcribing)
                            SizedBox(
                              height: 28,
                              child: Center(
                                child: MiuixInfiniteProgressIndicator(
                                  color: colors.onPrimary,
                                  size: 22,
                                ),
                              ),
                            )
                          else
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
                          label: tr('取消'),
                          active: z == VoiceZone.cancel,
                          activeColor: colors.error,
                        ),
                        _ZoneButton(
                          icon: AppIcons.edit,
                          label: tr('转文字'),
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
                    child: ListenableBuilder(
                      listenable: voice,
                      builder: (context, _) => MiuixText(
                        voice.transcribing
                            ? tr('正在识别…')
                            : switch (z) {
                                VoiceZone.send => tr('松开 发送'),
                                VoiceZone.cancel => tr('松开 取消'),
                                VoiceZone.edit => tr('松开 转为文字'),
                              },
                        fontSize: 15,
                        color: z == VoiceZone.send
                            ? Colors.black87
                            : Colors.white,
                      ),
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
