import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../data/voice_service.dart';
import '../../l10n/tr.dart';
import '../../ui/dialogs.dart';
import '../../ui/settings_widgets.dart';

/// 语音输入设置：系统识别 / 模型转写（选渠道和模型）。
class VoicePage extends ConsumerStatefulWidget {
  const VoicePage({super.key});

  @override
  ConsumerState<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends ConsumerState<VoicePage> {
  VoiceService get _voice => ref.read(voiceServiceProvider);

  /// 只有 OpenAI 格式的渠道有 /audio/transcriptions。
  List<Channel> get _channels => [
    for (final s in ref.watch(channelsProvider).value ?? const [])
      if (s.protocol.isOpenAI && s.channel.enabled) s.channel,
  ];

  Future<void> _setEngine(VoiceEngine e, List<Channel> channels) async {
    await _voice.setEngine(e);
    // 第一次打开模型转写：默认选第一个渠道和它的推荐模型。
    if (e == VoiceEngine.model &&
        channels.isNotEmpty &&
        !channels.any((c) => c.id == _voice.channelId)) {
      await _setChannel(channels.first);
    }
    setState(() {});
  }

  Future<void> _setChannel(Channel c) async {
    await _voice.setChannelId(c.id);
    await _voice.setModel(defaultTranscriptionModel(c.presetId, c.baseUrl));
    setState(() {});
  }

  Future<void> _pickModel(Channel? channel) async {
    final own = channel == null
        ? const <String>{}
        : await ref
              .read(channelRepositoryProvider)
              .channelModelNames(channel.id);
    final options = {
      ...own.where(looksLikeTranscriptionModel),
      ...transcriptionModels,
    };
    if (!mounted) return;
    String? picked;
    await showActionSheet(
      context,
      title: tr('转写模型'),
      actions: [
        for (final m in options) SheetAction(m, () => picked = m),
        SheetAction(tr('自定义…'), () => picked = ''),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked!.isEmpty) {
      picked = await showTextInput(
        context,
        title: tr('转写模型'),
        initial: _voice.model,
        label: tr('模型名，如 whisper-1'),
        autocorrect: false,
      );
    }
    if (picked == null || picked!.trim().isEmpty) return;
    await _voice.setModel(picked!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final engine = _voice.engine;
    final channels = _channels;
    final idx = channels.indexWhere((c) => c.id == _voice.channelId);
    final channel = idx < 0 ? null : channels[idx];
    // 选过的渠道被删了：换成第一个，免得界面显示的和实际用的不一致。
    if (engine == VoiceEngine.model && idx < 0 && channels.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setChannel(channels.first);
      });
    }
    return SettingsScaffold(
      title: tr('语音输入'),
      children: [
        SettingsGroup(
          children: [
            MiuixOverlayDropdownPreference(
              title: tr('识别方式'),
              items: [for (final e in VoiceEngine.values) e.label],
              selectedIndex: engine.index,
              onSelectedIndexChange: (i) =>
                  _setEngine(VoiceEngine.values[i], channels),
            ),
          ],
        ),
        if (engine == VoiceEngine.model)
          SettingsGroup(
            title: tr('转写模型'),
            children: [
              if (channels.isEmpty)
                MiuixBasicComponent(
                  title: tr('没有可用的渠道'),
                  summary: tr('先添加一个 OpenAI 格式的渠道；没设置好时仍用系统识别'),
                )
              else
                MiuixOverlayDropdownPreference(
                  title: tr('转写渠道'),
                  items: [for (final c in channels) c.name],
                  selectedIndex: idx < 0 ? 0 : idx,
                  onSelectedIndexChange: (i) => _setChannel(channels[i]),
                ),
              if (channels.isNotEmpty)
                MiuixArrowPreference(
                  title: tr('模型名'),
                  summary: _voice.model.isEmpty ? tr('未设置') : _voice.model,
                  onClick: () => _pickModel(channel),
                ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
          child: MiuixText(
            tr(
              '系统识别：边说边出字，免费，但一次只认一种语言，中文里夹的英文容易认错。\n\n模型转写：松手后把录音发给所选渠道的语音模型，中英混说也能认对，比如「这个 style 我不喜欢」。按渠道的价格计费；录音只发给这个渠道，识别完就删除。\n\n推荐：OpenAI 的 gpt-4o-transcribe，硅基流动的 FunAudioLLM/SenseVoiceSmall，Groq 的 whisper-large-v3-turbo，智谱的 glm-asr。',
            ),
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
        ),
      ],
    );
  }
}
