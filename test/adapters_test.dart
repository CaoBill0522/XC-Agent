import 'dart:convert';

import 'package:agent/core/api/adapters/adapter.dart';
import 'package:agent/core/api/adapters/anthropic_adapter.dart';
import 'package:agent/core/api/adapters/openai_chat_adapter.dart';
import 'package:agent/core/api/adapters/openai_responses_adapter.dart';
import 'package:agent/core/api/api_error.dart';
import 'package:agent/core/api/endpoint.dart';
import 'package:agent/core/api/protocol.dart';
import 'package:agent/core/api/sse.dart';
import 'package:agent/core/chat/chat_types.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<ChatEvent>> run(ProtocolAdapter a, String sse) async {
  final out = <ChatEvent>[];
  await for (final e in parseSse(Stream.value(utf8.encode(sse)))) {
    out.addAll(a.parseEvent(e));
  }
  return out;
}

String texts(List<ChatEvent> es) =>
    es.whereType<TextDelta>().map((e) => e.text).join();
String thinks(List<ChatEvent> es) =>
    es.whereType<ThinkingDelta>().map((e) => e.text).join();

const _img = InlineImage(base64: 'AAAA', mime: 'image/png');

void main() {
  group('SSE 解析', () {
    test('多行 data、CRLF、注释行、事件名', () async {
      final events = await parseSse(
        Stream.value(
          utf8.encode(
            ': keep-alive\r\nevent: foo\r\ndata: a\r\ndata: b\r\n\r\ndata: [DONE]\n\n',
          ),
        ),
      ).toList();
      expect(events, hasLength(2));
      expect(events[0].event, 'foo');
      expect(events[0].data, 'a\nb');
      expect(events[1].isDone, isTrue);
    });

    test('跨 chunk 切断的 UTF-8 中文不乱码', () async {
      final bytes = utf8.encode('data: {"t":"你好"}\n\n');
      final chunks = [bytes.sublist(0, 12), bytes.sublist(12)];
      final events = await parseSse(Stream.fromIterable(chunks)).toList();
      expect(jsonDecode(events.single.data)['t'], '你好');
    });
  });

  group('OpenAI Chat', () {
    const a = OpenAIChatAdapter();

    test('请求体：system、图片、推理强度只给推理模型', () {
      final body = a.buildBody(
        const ChatRequest(
          model: 'gpt-4o',
          system: 'sys',
          turns: [
            ChatTurn(role: 'user', text: 'hi', images: [_img]),
          ],
          params: GenParams(temperature: 0.5, reasoning: ReasoningEffort.high),
        ),
      );
      final msgs = body['messages'] as List;
      expect(msgs.first, {'role': 'system', 'content': 'sys'});
      final content = (msgs[1] as Map)['content'] as List;
      expect(content[1]['image_url']['url'], 'data:image/png;base64,AAAA');
      expect(body['temperature'], 0.5);
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body['stream'], isTrue);
    });

    test('智谱联网用 tools.web_search', () {
      final body = a.buildBody(
        const ChatRequest(
          model: 'glm-4.5',
          turns: [],
          webSearch: true,
          presetId: 'zhipu',
        ),
      );
      expect((body['tools'] as List).first['type'], 'web_search');
    });

    test('流式：内容、DeepSeek 推理、usage', () async {
      final es = await run(a, '''
data: {"choices":[{"delta":{"reasoning_content":"想一想"}}]}

data: {"choices":[{"delta":{"content":"你"}}]}

data: {"choices":[{"delta":{"content":"好"}}]}

data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}

data: [DONE]

''');
      expect(texts(es), '你好');
      expect(thinks(es), '想一想');
      expect(es.whereType<UsageEvent>().single.output, 2);
    });

    test('流中的 error 对象抛出可读错误', () async {
      expect(
        run(a, 'data: {"error":{"message":"quota exceeded"}}\n\n'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.detail,
            'detail',
            'quota exceeded',
          ),
        ),
      );
    });

    test('非流式兜底：完整 JSON', () {
      final es = a.parseFull({
        'choices': [
          {
            'message': {'content': 'ok', 'reasoning_content': 'r'},
          },
        ],
      }).toList();
      expect(texts(es), 'ok');
      expect(thinks(es), 'r');
    });
  });

  group('OpenAI Responses', () {
    const a = OpenAIResponsesAdapter();

    test('请求体：input / instructions / web_search / 推理摘要', () {
      final body = a.buildBody(
        const ChatRequest(
          model: 'gpt-5',
          system: 'sys',
          webSearch: true,
          reasoningCapable: true,
          presetId: 'openai',
          turns: [
            ChatTurn(role: 'user', text: 'q', images: [_img]),
            ChatTurn(role: 'assistant', text: 'a'),
          ],
        ),
      );
      expect(body['instructions'], 'sys');
      final input = body['input'] as List;
      expect(input[0]['content'][1], {
        'type': 'input_image',
        'image_url': 'data:image/png;base64,AAAA',
      });
      expect(input[1]['content'][0]['type'], 'output_text');
      expect(body['tools'], [
        {'type': 'web_search'},
      ]);
      expect(body['reasoning'], {'summary': 'auto'});
    });

    test('非 OpenAI 官方的默认推理强度不发 reasoning 参数', () {
      final body = a.buildBody(
        const ChatRequest(
          model: 'grok-4',
          turns: [],
          reasoningCapable: true,
          presetId: 'xai',
        ),
      );
      expect(body.containsKey('reasoning'), isFalse);
    });

    test('流式：文本、推理摘要、引用、usage、失败', () async {
      final es = await run(a, '''
event: response.reasoning_summary_text.delta
data: {"type":"response.reasoning_summary_text.delta","delta":"思考"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"答案"}

event: response.output_text.annotation.added
data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"https://a.com","title":"A"}}

event: response.completed
data: {"type":"response.completed","response":{"usage":{"input_tokens":5,"output_tokens":7}}}

''');
      expect(texts(es), '答案');
      expect(thinks(es), '思考');
      expect(es.whereType<CitationEvent>().single.url, 'https://a.com');
      expect(es.whereType<UsageEvent>().single.output, 7);

      expect(
        run(
          a,
          'data: {"type":"response.failed","response":{"error":{"message":"bad"}}}\n\n',
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('Anthropic', () {
    const a = AnthropicAdapter();

    test('请求体：必填 max_tokens、合并同角色、图片在前、thinking 时不传 temperature', () {
      final body = a.buildBody(
        const ChatRequest(
          model: 'claude-sonnet-4-5',
          reasoningCapable: true,
          params: GenParams(temperature: 0.3, reasoning: ReasoningEffort.low),
          turns: [
            ChatTurn(role: 'user', text: 'a'),
            ChatTurn(role: 'user', text: 'b', images: [_img]),
          ],
        ),
      );
      final msgs = body['messages'] as List;
      expect(msgs, hasLength(1));
      final blocks = msgs.single['content'] as List;
      expect(blocks.map((b) => b['type']), ['text', 'image', 'text']);
      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 2048});
      expect(body['max_tokens'], 2048 + AnthropicAdapter.defaultMaxTokens);
      expect(body.containsKey('temperature'), isFalse);
    });

    test('未开推理时传 temperature，不传 thinking', () {
      final body = a.buildBody(
        const ChatRequest(
          model: 'claude-3-5-haiku',
          turns: [],
          params: GenParams(temperature: 0.3),
        ),
      );
      expect(body['temperature'], 0.3);
      expect(body.containsKey('thinking'), isFalse);
      expect(body['max_tokens'], AnthropicAdapter.defaultMaxTokens);
    });

    test('流式：thinking、文本、搜索结果、引用、错误', () async {
      final es = await run(a, '''
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"嗯"}}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","content":[{"type":"web_search_result","url":"https://b.com","title":"B"}]}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"结果"}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://b.com","title":"B"}}}

event: message_delta
data: {"type":"message_delta","usage":{"output_tokens":4}}

''');
      expect(thinks(es), '嗯');
      expect(texts(es), '结果');
      expect(es.whereType<CitationEvent>().map((c) => c.url), [
        'https://b.com',
        'https://b.com',
      ]);
      expect(es.whereType<UsageEvent>().map((u) => u.output).whereType<int>(), [
        4,
      ]);

      expect(
        run(
          a,
          'event: error\ndata: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}\n\n',
        ),
        throwsA(
          isA<ApiException>().having((e) => e.detail, 'detail', 'Overloaded'),
        ),
      );
    });
  });

  test('ContentPart 编解码往返', () {
    final parts = [
      const ThinkingPart('t'),
      const TextPart('x'),
      const ImagePart('a.png', 'image/png'),
      const CitationPart('https://u', 'U'),
    ];
    final back = ContentPart.decodeList(ContentPart.encodeList(parts));
    expect(back.text, 'x');
    expect(back.thinking, 't');
    expect(back.images.single.path, 'a.png');
    expect(back.citations.single.title, 'U');
  });

  group('DeepSeek 联网搜索', () {
    bool ok(
      ApiProtocol p,
      String model, {
      String preset = 'deepseek',
      String base = '',
    }) => supportsWebSearch(
      protocol: p,
      presetId: preset,
      model: model,
      baseUrl: base,
    );

    test(
      '支持规则：OpenAI 格式（自动改走 Anthropic 兼容接口）、Anthropic 格式都可以；Responses 只有 v4-pro',
      () {
        expect(ok(ApiProtocol.openaiChat, 'deepseek-flash'), isTrue);
        expect(ok(ApiProtocol.anthropic, 'deepseek-flash'), isTrue);
        expect(ok(ApiProtocol.openaiResponses, 'deepseek-flash'), isFalse);
        expect(ok(ApiProtocol.openaiResponses, 'deepseek-v4-pro'), isTrue);
        // 自定义渠道填官方地址也算；其它中转站仍按原规则。
        expect(
          ok(
            ApiProtocol.openaiChat,
            'deepseek-v4-pro',
            preset: 'custom',
            base: 'https://api.deepseek.com/v1',
          ),
          isTrue,
        );
        expect(
          ok(
            ApiProtocol.openaiChat,
            'deepseek-v4-pro',
            preset: 'custom',
            base: 'https://relay.example.com/v1',
          ),
          isFalse,
        );
      },
    );

    test('联网端点：DeepSeek 官方改走同 Key 的 Anthropic 兼容接口；中转站的 Claude 模型不变', () {
      final e = ChannelEndpoint(
        protocol: ApiProtocol.openaiChat,
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-ds',
      ).forWebSearch(presetId: 'deepseek', model: 'deepseek-v4-pro');
      expect(e.protocol, ApiProtocol.anthropic);
      expect(
        e.chatUrl.toString(),
        'https://api.deepseek.com/anthropic/v1/messages',
      );
      expect(e.headers['x-api-key'], 'sk-ds');

      final relay = ChannelEndpoint(
        protocol: ApiProtocol.openaiChat,
        baseUrl: 'https://relay.example.com/v1',
        apiKey: 'k',
      );
      expect(
        identical(
          relay.forWebSearch(presetId: 'custom', model: 'claude-sonnet-4-5'),
          relay,
        ),
        isTrue,
      );
    });
  });

  group('中转站 GPT 联网（改走 Responses）', () {
    bool ok(String model, {String preset = 'custom'}) => supportsWebSearch(
      protocol: ApiProtocol.openaiChat,
      presetId: preset,
      model: model,
      baseUrl: 'https://relay.example.com/v1',
    );

    test('支持规则：GPT / o 系列 / Grok 可以；Claude、生图、嵌入等不行', () {
      for (final m in [
        'gpt-4o',
        'gpt-5',
        'o3-mini',
        'grok-4',
        'openai/gpt-4.1',
      ]) {
        expect(ok(m), isTrue, reason: m);
      }
      for (final m in [
        'claude-sonnet-4-5',
        'gpt-image-1',
        'text-embedding-3-small',
        'gpt-4o-realtime-preview',
        'glm-4.5',
      ]) {
        expect(ok(m), isFalse, reason: m);
      }
      expect(ok('gpt-4o', preset: 'openai'), isTrue);
    });

    test('联网端点：同地址、同 Key 的 Responses 接口；search 模型仍走 Chat', () {
      final chat = ChannelEndpoint(
        protocol: ApiProtocol.openaiChat,
        baseUrl: 'https://relay.example.com/v1',
        apiKey: 'sk-r',
      );
      final e = chat.forWebSearch(presetId: 'custom', model: 'gpt-4o');
      expect(e.protocol, ApiProtocol.openaiResponses);
      expect(e.chatUrl.toString(), 'https://relay.example.com/v1/responses');
      expect(e.headers['Authorization'], 'Bearer sk-r');
      expect(
        identical(
          chat.forWebSearch(presetId: 'custom', model: 'gpt-4o-search-preview'),
          chat,
        ),
        isTrue,
      );
    });
  });

  group('PDF 附件', () {
    const pdf = InlineFile(
      name: 'a.pdf',
      mime: 'application/pdf',
      base64: 'QUJD',
    );
    ChatRequest req() => const ChatRequest(
      model: 'm',
      turns: [
        ChatTurn(role: 'user', text: '总结', files: [pdf]),
      ],
    );

    test('Anthropic：document 块', () {
      final body = const AnthropicAdapter().buildBody(req());
      final block =
          ((body['messages'] as List).single['content'] as List).first;
      expect(block['type'], 'document');
      expect(block['source'], {
        'type': 'base64',
        'media_type': 'application/pdf',
        'data': 'QUJD',
      });
    });

    test('Responses：input_file', () {
      final body = const OpenAIResponsesAdapter().buildBody(req());
      final parts = ((body['input'] as List).single['content'] as List);
      expect(parts.last, {
        'type': 'input_file',
        'filename': 'a.pdf',
        'file_data': 'data:application/pdf;base64,QUJD',
      });
    });
  });
}
