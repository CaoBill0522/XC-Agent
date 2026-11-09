import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent/core/api/api_error.dart';
import 'package:agent/core/api/endpoint.dart';
import 'package:agent/core/api/protocol.dart';
import 'package:agent/data/voice_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Http implements HttpClientAdapter {
  _Http(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions o) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? _,
    Future<void>? cancelFuture,
  ) async {
    requests.add(o);
    return handler(o);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

void main() {
  late File audio;
  setUp(() {
    audio = File('${Directory.systemTemp.createTempSync().path}/a.wav')
      ..writeAsBytesSync(List.filled(64, 1));
  });

  Transcriber make(_Http http, {String base = 'https://api.example.com'}) =>
      Transcriber(
        ChannelEndpoint(
          protocol: ApiProtocol.openaiChat,
          baseUrl: base,
          apiKey: 'sk-test',
        ),
        'gpt-4o-transcribe',
        Dio()..httpClientAdapter = http,
      );

  test('发到 /v1/audio/transcriptions，带模型、提示和录音文件，不指定语言', () async {
    final http = _Http((_) => _json({'text': ' 这个style我不喜欢 '}));
    final text = await make(http).transcribe(audio.path);
    expect(text, '这个style我不喜欢');
    final r = http.requests.single;
    expect(r.uri.toString(), 'https://api.example.com/v1/audio/transcriptions');
    expect(r.headers['Authorization'], 'Bearer sk-test');
    final form = r.data as FormData;
    final fields = Map.fromEntries(form.fields);
    expect(fields['model'], 'gpt-4o-transcribe');
    expect(fields.containsKey('language'), isFalse);
    expect(fields['prompt'], contains('style'));
    expect(form.files.single.key, 'file');
    expect(form.files.single.value.filename, 'a.wav');
  });

  test('接口报错时抛出 ApiException', () async {
    final http = _Http((_) => _json({
      'error': {'message': 'model not found'},
    }, 404));
    await expectLater(
      make(http).transcribe(audio.path),
      throwsA(isA<ApiException>()),
    );
  });

  test('解析返回：JSON 或纯文本', () {
    expect(parseTranscription({'text': ' hi '}), 'hi');
    expect(parseTranscription(' 你好 '), '你好');
    expect(parseTranscription(null), '');
  });

  test('按渠道给默认转写模型', () {
    expect(defaultTranscriptionModel('openai', ''), 'gpt-4o-transcribe');
    expect(defaultTranscriptionModel('zhipu', ''), 'glm-asr');
    expect(
      defaultTranscriptionModel('custom', 'https://api.siliconflow.cn/v1'),
      'FunAudioLLM/SenseVoiceSmall',
    );
    expect(defaultTranscriptionModel('custom', 'https://x.com'), 'whisper-1');
    expect(looksLikeTranscriptionModel('openai/whisper-1'), isTrue);
    expect(looksLikeTranscriptionModel('gpt-4o'), isFalse);
  });
}
