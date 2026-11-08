import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent/core/api/api_error.dart';
import 'package:agent/core/api/channel_client.dart';
import 'package:agent/core/api/endpoint.dart';
import 'package:agent/core/api/protocol.dart';
import 'package:agent/core/providers/provider_preset.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求并按脚本返回响应的假适配器。
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? _,
    Future<void>? _,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [ContentType.json.toString()],
      },
    );

void main() {
  group('Base URL 规范化', () {
    String norm(ApiProtocol p, String s) =>
        ChannelEndpoint.normalizeBaseUrl(p, s);

    test('OpenAI 系：只填域名时补 /v1，已有路径保持不变', () {
      expect(
        norm(ApiProtocol.openaiChat, 'https://api.deepseek.com'),
        'https://api.deepseek.com/v1',
      );
      expect(
        norm(ApiProtocol.openaiChat, 'https://api.openai.com/v1/'),
        'https://api.openai.com/v1',
      );
      expect(
        norm(ApiProtocol.openaiChat, 'https://open.bigmodel.cn/api/paas/v4/'),
        'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(
        norm(ApiProtocol.openaiResponses, 'relay.example.com'),
        'https://relay.example.com/v1',
      );
    });

    test('Anthropic：去掉误带的 /v1', () {
      expect(
        norm(ApiProtocol.anthropic, 'https://api.anthropic.com/v1'),
        'https://api.anthropic.com',
      );
      expect(
        norm(ApiProtocol.anthropic, 'https://open.bigmodel.cn/api/anthropic/'),
        'https://open.bigmodel.cn/api/anthropic',
      );
    });

    test('端点和鉴权头', () {
      final oa = ChannelEndpoint(
        protocol: ApiProtocol.openaiChat,
        baseUrl: 'https://x.com',
        apiKey: 'k',
      );
      expect(oa.modelsUrl.toString(), 'https://x.com/v1/models');
      expect(oa.chatUrl.toString(), 'https://x.com/v1/chat/completions');
      expect(oa.headers['Authorization'], 'Bearer k');

      final an = ChannelEndpoint(
        protocol: ApiProtocol.anthropic,
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'k',
      );
      expect(an.modelsUrl.toString(), 'https://api.anthropic.com/v1/models');
      expect(an.chatUrl.toString(), 'https://api.anthropic.com/v1/messages');
      expect(an.headers['x-api-key'], 'k');
      expect(an.headers['anthropic-version'], kAnthropicVersion);
      expect(an.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('模型列表解析', () {
    test('OpenAI 格式', () {
      final r = parseModelList({
        'object': 'list',
        'data': [
          {'id': 'gpt-4o', 'owned_by': 'openai'},
          {'id': 'gpt-image-1'},
        ],
      });
      expect(r.models.map((m) => m.id), ['gpt-4o', 'gpt-image-1']);
      expect(r.models.first.ownedBy, 'openai');
    });

    test('Anthropic 格式（带分页）', () {
      final r = parseModelList({
        'data': [
          {
            'id': 'claude-sonnet-4-5',
            'display_name': 'Claude Sonnet 4.5',
            'type': 'model',
          },
        ],
        'has_more': true,
        'last_id': 'claude-sonnet-4-5',
      });
      expect(r.models.single.displayName, 'Claude Sonnet 4.5');
      expect(r.hasMore, isTrue);
      expect(r.lastId, 'claude-sonnet-4-5');
    });

    test('中转站的非标准格式', () {
      expect(parseModelList(['a', 'b']).models.map((m) => m.id), ['a', 'b']);
      expect(
        parseModelList({
          'models': [
            {'name': 'x'},
          ],
        }).models.single.id,
        'x',
      );
      expect(() => parseModelList({'foo': 1}), throwsA(isA<ApiException>()));
    });
  });

  group('ChannelClient', () {
    test('Anthropic 自动翻页、去重并排序', () async {
      final adapter = FakeAdapter((o) {
        final after = o.uri.queryParameters['after_id'];
        return after == null
            ? jsonBody({
                'data': [
                  {'id': 'b'},
                  {'id': 'a'},
                ],
                'has_more': true,
                'last_id': 'a',
              })
            : jsonBody({
                'data': [
                  {'id': 'c'},
                  {'id': 'a'},
                ],
                'has_more': false,
              });
      });
      final client = ChannelClient(Dio()..httpClientAdapter = adapter);
      final models = await client.listModels(
        ChannelEndpoint(
          protocol: ApiProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'k',
        ),
      );
      expect(models.map((m) => m.id), ['a', 'b', 'c']);
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.first.uri.queryParameters['limit'], '1000');
      expect(adapter.requests.last.uri.queryParameters['after_id'], 'a');
      expect(adapter.requests.first.headers['x-api-key'], 'k');
    });

    test('401 转成可读的中文错误，并带上服务端信息', () async {
      final client = ChannelClient(
        Dio()
          ..httpClientAdapter = FakeAdapter(
            (_) => jsonBody({
              'error': {'message': 'Incorrect API key provided'},
            }, 401),
          ),
      );
      await expectLater(
        client.listModels(
          ChannelEndpoint(
            protocol: ApiProtocol.openaiChat,
            baseUrl: 'https://x.com',
            apiKey: 'bad',
          ),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', 'API Key 无效或未填写')
              .having((e) => e.detail, 'detail', 'Incorrect API key provided'),
        ),
      );
    });

    test('连通性测试：max_tokens 相关的 400 视为连接正常', () async {
      final client = ChannelClient(
        Dio()
          ..httpClientAdapter = FakeAdapter(
            (_) => jsonBody({
              'error': {
                'message': "Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens' instead.",
              },
            }, 400),
          ),
      );
      final r = await client.testChat(
        ChannelEndpoint(
          protocol: ApiProtocol.openaiChat,
          baseUrl: 'https://x.com',
          apiKey: 'k',
        ),
        'o3',
      );
      expect(r.message, contains('连接正常'));
    });

    test('连通性测试：其它 400 照常报错', () async {
      final client = ChannelClient(
        Dio()
          ..httpClientAdapter = FakeAdapter(
            (_) => jsonBody({
              'error': {'message': 'invalid token'},
            }, 400),
          ),
      );
      await expectLater(
        client.testChat(
          ChannelEndpoint(
            protocol: ApiProtocol.openaiChat,
            baseUrl: 'https://x.com',
            apiKey: 'k',
          ),
          'm',
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });

  test('预设文件可解析，且每个预设至少一个端点', () {
    final presets = ProviderPreset.parseAll(
      File('assets/presets/providers.json').readAsStringSync(),
    );
    expect(
      presets.map((p) => p.id),
      containsAll([
        'openai',
        'anthropic',
        'xai',
        'zhipu',
        'deepseek',
        'custom',
      ]),
    );
    for (final p in presets) {
      expect(p.endpoints, isNotEmpty, reason: p.id);
    }
    final deepseek = presets.firstWhere((p) => p.id == 'deepseek');
    // 2026-10 起官方 Anthropic 兼容接口接受 deepseek-* 模型名并支持服务端联网搜索。
    expect(
      deepseek.endpointFor(ApiProtocol.anthropic)?.baseUrl,
      kDeepSeekAnthropicBase,
    );
    expect(deepseek.endpoints.first.protocol, ApiProtocol.openaiChat);
  });
}
