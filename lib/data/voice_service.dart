import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api/api_error.dart';
import '../core/api/endpoint.dart';
import '../core/api/protocol.dart';
import '../l10n/tr.dart';
import 'db/app_database.dart';
import 'repositories/channel_repository.dart';

/// 语音输入用哪种识别方式。
enum VoiceEngine {
  /// 系统识别：边说边出字、不花钱，但一次只能认一种语言，中文里夹的英文常认错。
  system,

  /// 模型转写：松手后把录音交给渠道里的语音模型（gpt-4o-transcribe、
  /// SenseVoice、Whisper 等），中英混说也能认对。
  model;

  String get label => switch (this) {
    system => tr('系统识别'),
    model => tr('模型转写'),
  };
}

/// 常见的语音转写模型（都走 OpenAI 格式的 /audio/transcriptions）。
const transcriptionModels = [
  'gpt-4o-transcribe',
  'gpt-4o-mini-transcribe',
  'whisper-1',
  'FunAudioLLM/SenseVoiceSmall',
  'whisper-large-v3-turbo',
  'glm-asr',
];

/// 按渠道预设给一个默认的转写模型。
String defaultTranscriptionModel(String presetId, String baseUrl) {
  if (presetId == 'openai') return 'gpt-4o-transcribe';
  if (presetId == 'zhipu') return 'glm-asr';
  if (baseUrl.contains('siliconflow')) return 'FunAudioLLM/SenseVoiceSmall';
  if (baseUrl.contains('groq.com')) return 'whisper-large-v3-turbo';
  return 'whisper-1';
}

/// 名字像语音转写模型的（从渠道的模型列表里挑出来给用户选）。
bool looksLikeTranscriptionModel(String id) => RegExp(
  r'transcribe|whisper|sensevoice|asr|paraformer|speech-to-text|stt',
  caseSensitive: false,
).hasMatch(id);

/// 语音输入设置 + 模型转写。
class VoiceService {
  VoiceService(SharedPreferences Function() prefs, this._channels, {Dio? dio})
    : _prefsOf = prefs,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

  final SharedPreferences Function() _prefsOf;
  SharedPreferences get _prefs => _prefsOf();
  final ChannelRepository _channels;
  final Dio _dio;

  static const _engineKey = 'voice_engine';
  static const _channelKey = 'voice_channel';
  static const _modelKey = 'voice_model';

  VoiceEngine get engine => VoiceEngine.values.firstWhere(
    (e) => e.name == _prefs.getString(_engineKey),
    orElse: () => VoiceEngine.system,
  );
  Future<void> setEngine(VoiceEngine e) => _prefs.setString(_engineKey, e.name);

  String? get channelId => _prefs.getString(_channelKey);
  Future<void> setChannelId(String id) => _prefs.setString(_channelKey, id);

  String get model => _prefs.getString(_modelKey) ?? '';
  Future<void> setModel(String m) => _prefs.setString(_modelKey, m.trim());

  /// 选了模型转写且渠道还在时返回转写器，否则用系统识别。
  Future<Transcriber?> transcriber() async {
    if (engine != VoiceEngine.model) return null;
    final id = channelId;
    if (id == null || model.isEmpty) return null;
    final Channel? ch = await _channels.getChannel(id);
    if (ch == null || !ch.enabled) return null;
    if (!ApiProtocol.fromId(ch.protocol).isOpenAI) return null;
    return Transcriber(await _channels.endpointFor(ch), model, _dio);
  }
}

/// 调用 OpenAI 格式的 `/audio/transcriptions`。
class Transcriber {
  Transcriber(this.endpoint, this.model, this._dio);

  final ChannelEndpoint endpoint;
  final String model;
  final Dio _dio;

  /// 给模型的提示：不指定语言（自动识别，才能中英混说），
  /// 用一句中英夹杂的话示范「英文保持英文」。
  static String get prompt => L10n.isEn
      ? 'The speaker may mix English and Chinese. Keep each word in the language it was spoken.'
      : '以下是普通话，中间可能夹杂英文单词，英文保持英文原样，例如：这个 style 我不喜欢，帮我 review 一下这段 code。';

  Future<String> transcribe(String path, {CancelToken? cancel}) async {
    final file = File(path);
    final form = FormData.fromMap({
      'model': model,
      'response_format': 'json',
      'prompt': prompt,
      'file': await MultipartFile.fromFile(
        file.path,
        filename: file.uri.pathSegments.last,
      ),
    });
    final Response<Object?> res;
    try {
      res = await _dio.postUri(
        endpoint.url('/audio/transcriptions'),
        data: form,
        cancelToken: cancel,
        options: Options(headers: endpoint.headers),
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
    return parseTranscription(res.data);
  }
}

/// 兼容 `{"text": "..."}`、纯文本两种返回。
String parseTranscription(Object? data) {
  if (data is Map && data['text'] is String) {
    return (data['text'] as String).trim();
  }
  if (data is String) return data.trim();
  return '';
}
