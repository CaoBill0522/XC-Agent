import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent/core/api/adapters/anthropic_adapter.dart';
import 'package:agent/core/api/adapters/openai_chat_adapter.dart';
import 'package:agent/core/api/adapters/openai_responses_adapter.dart';
import 'package:agent/core/api/sse.dart';
import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/core/tools/calculator.dart';
import 'package:agent/core/tools/mcp_client.dart';
import 'package:agent/data/tool_service.dart';
import 'package:agent/features/chat/code_preview.dart';
import 'package:agent/features/home/quick_entry.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _spec = ToolSpec(
  name: 'calculate',
  description: 'calc',
  parameters: {'type': 'object'},
);

const _turns = [
  ChatTurn(role: 'user', text: '算一下 1+1'),
  ChatTurn(
    role: 'assistant',
    text: '我来算',
    thinking: '想想',
    thinkingSignature: 'sig',
    toolCalls: [
      ToolCall(id: 'c1', name: 'calculate', arguments: '{"expression":"1+1"}'),
    ],
  ),
  ChatTurn(
    role: 'tool',
    text: '',
    toolResults: [ToolResult(callId: 'c1', name: 'calculate', content: '2')],
  ),
];

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

void main() {
  group('计算器', () {
    test('四则运算、优先级、乘方右结合、函数和常量', () {
      expect(evaluateExpression('1 + 2 * 3'), 7);
      expect(evaluateExpression('(1+2)*3'), 9);
      expect(evaluateExpression('2^3^2'), 512);
      expect(evaluateExpression('-2^2'), -4);
      expect(evaluateExpression('sqrt(16) + abs(-3)'), 7);
      expect(evaluateExpression('5!'), 120);
      expect(evaluateExpression('10 % 4'), 2);
      expect(evaluateExpression('max(1, 7, 3)'), 7);
      expect(evaluateExpression('2×3÷4'), 1.5);
      expect(evaluateExpression('pi'), closeTo(3.14159, 1e-5));
    });

    test('错误输入抛 FormatException', () {
      expect(() => evaluateExpression('1 +'), throwsFormatException);
      expect(() => evaluateExpression('(1+2'), throwsFormatException);
      expect(() => evaluateExpression('foo(1)'), throwsFormatException);
      expect(() => evaluateExpression('import os'), throwsFormatException);
    });

    test('结果格式化', () {
      expect(formatNumber(3), '3');
      expect(formatNumber(0.1 + 0.2), '0.3');
      expect(formatNumber(1 / 3), '0.333333333333');
    });
  });

  test('网页转文字：去掉脚本样式，块级换行，解码实体', () {
    final (title, text) = htmlToText('''
<html><head><title>标题 &amp; 副标题</title><style>p{}</style></head>
<body><nav>菜单</nav><script>alert(1)</script>
<h1>大标题</h1><p>第一段&nbsp;文字</p><ul><li>一</li><li>二</li></ul>
<p>价格 &lt;100&gt; &#20803;</p></body></html>''');
    expect(title, '标题 & 副标题');
    expect(text, isNot(contains('alert')));
    expect(text, isNot(contains('菜单')));
    expect(text, contains('大标题'));
    expect(text, contains('第一段 文字'));
    expect(text, contains('- 一'));
    expect(text, contains('价格 <100> 元'));
  });

  group('协议适配：工具调用', () {
    test('OpenAI Chat：tools 定义、assistant tool_calls、tool 结果', () {
      final body = const OpenAIChatAdapter().buildBody(
        const ChatRequest(model: 'm', turns: _turns, tools: [_spec]),
      );
      final msgs = body['messages'] as List;
      expect(msgs[1]['tool_calls'][0]['function']['name'], 'calculate');
      expect(msgs[1]['content'], '我来算');
      expect(msgs[1].containsKey('reasoning_content'), isFalse);
      expect(msgs[2], {'role': 'tool', 'tool_call_id': 'c1', 'content': '2'});
      expect(body['tools'][0]['function']['name'], 'calculate');
    });

    test('OpenAI Chat：DeepSeek 带回本轮思考内容', () {
      final body = const OpenAIChatAdapter().buildBody(
        const ChatRequest(
          model: 'm',
          turns: _turns,
          tools: [_spec],
          presetId: 'deepseek',
        ),
      );
      expect((body['messages'] as List)[1]['reasoning_content'], '想想');
    });

    test('OpenAI Chat：流式 tool_calls 片段带 index', () {
      final events = [
        for (final d in [
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_1',
                      'function': {'name': 'calculate', 'arguments': '{"ex'},
                    },
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': 'pression":"2"}'},
                    },
                  ],
                },
              },
            ],
          },
        ])
          ...const OpenAIChatAdapter().parseEvent(
            SseEvent(null, jsonEncode(d)),
          ),
      ].cast<ToolCallDelta>();
      expect(events.map((e) => e.index), [0, 0]);
      expect(events.first.id, 'call_1');
      expect(events.map((e) => e.arguments).join(), '{"expression":"2"}');
    });

    test('Anthropic：带签名的思考块、tool_use、tool_result 在 user 消息里', () {
      final body = const AnthropicAdapter().buildBody(
        const ChatRequest(model: 'claude', turns: _turns, tools: [_spec]),
      );
      final msgs = body['messages'] as List;
      final assistant = msgs[1]['content'] as List;
      expect(assistant.first, {
        'type': 'thinking',
        'thinking': '想想',
        'signature': 'sig',
      });
      expect(assistant.last['type'], 'tool_use');
      expect(assistant.last['input'], {'expression': '1+1'});
      expect(msgs[2]['role'], 'user');
      expect((msgs[2]['content'] as List).single['type'], 'tool_result');
      expect(body['tools'][0]['input_schema'], {'type': 'object'});
    });

    test('Anthropic：流式 tool_use 起始块 + input_json_delta', () {
      const a = AnthropicAdapter();
      final events = [
        ...a.parseEvent(
          SseEvent(
            null,
            jsonEncode({
              'type': 'content_block_start',
              'index': 2,
              'content_block': {
                'type': 'tool_use',
                'id': 'tu',
                'name': 'calculate',
                'input': <String, dynamic>{},
              },
            }),
          ),
        ),
        ...a.parseEvent(
          SseEvent(
            null,
            jsonEncode({
              'type': 'content_block_delta',
              'index': 2,
              'delta': {'type': 'input_json_delta', 'partial_json': '{"a":1}'},
            }),
          ),
        ),
      ].cast<ToolCallDelta>();
      expect(events.map((e) => e.index), [2, 2]);
      expect(events.first.name, 'calculate');
      expect(events.map((e) => e.arguments).join(), '{"a":1}');
    });

    test('Responses：function_call / function_call_output 输入项', () {
      final body = const OpenAIResponsesAdapter().buildBody(
        const ChatRequest(model: 'gpt', turns: _turns, tools: [_spec]),
      );
      final input = body['input'] as List;
      expect(input.map((i) => i['type'] ?? i['role']), [
        'user',
        'assistant',
        'function_call',
        'function_call_output',
      ]);
      expect(input[2]['call_id'], 'c1');
      expect(body['tools'][0]['type'], 'function');
    });
  });

  group('MCP 客户端', () {
    test('初始化拿会话 ID，列工具，调用工具（SSE 响应）', () async {
      final http = _Http((o) {
        final body = o.data as Map;
        final id = body['id'];
        switch (body['method']) {
          case 'initialize':
            return ResponseBody.fromString(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'result': {'protocolVersion': '2025-06-18'},
              }),
              200,
              headers: {
                'content-type': ['application/json'],
                'mcp-session-id': ['s1'],
              },
            );
          case 'tools/list':
            expect(o.headers['mcp-session-id'], 's1');
            return ResponseBody.fromString(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'tools': [
                    {
                      'name': 'weather',
                      'description': '查天气',
                      'inputSchema': {'type': 'object'},
                    },
                  ],
                },
              }),
              200,
              headers: {
                'content-type': ['application/json'],
              },
            );
          case 'tools/call':
            return ResponseBody.fromString(
              'event: message\ndata: ${jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'content': [
                    {'type': 'text', 'text': '晴 25°C'},
                  ],
                },
              })}\n\n',
              200,
              headers: {
                'content-type': ['text/event-stream'],
              },
            );
          default:
            return ResponseBody.fromString('', 202);
        }
      });
      final c = McpClient(
        'https://mcp.example.com/mcp',
        token: 't',
        dio: Dio()..httpClientAdapter = http,
      );
      final tools = await c.listTools();
      expect(tools.single.name, 'weather');
      final (text, isError) = await c.callTool('weather', {'city': '上海'});
      expect(text, '晴 25°C');
      expect(isError, isFalse);
      expect(http.requests.first.headers['authorization'], 'Bearer t');
      expect(http.requests.map((r) => (r.data as Map)['method']), [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/call',
      ]);
    });

    test('工具名清洗：只留字母数字下划线横线，最长 64', () {
      expect(ToolService.sanitizeName('我的 服务器_get.weather'), '_get_weather');
      expect(ToolService.sanitizeName('a' * 80).length, 64);
    });
  });

  test('当前时间描述包含星期和时区', () {
    final s = ToolService.describeNow(DateTime(2026, 11, 9, 8, 5, 3));
    expect(s, startsWith('2026-11-09 08:05:03 Monday'));
    expect(s, contains('UTC'));
  });

  test('代码预览：按语言识别 HTML / SVG / Mermaid', () {
    expect(previewKindOf('html', '<p>'), PreviewKind.html);
    expect(previewKindOf('xml', '<svg></svg>'), PreviewKind.svg);
    expect(previewKindOf('xml', '<a/>'), isNull);
    expect(previewKindOf('mermaid', 'graph TD'), PreviewKind.mermaid);
    expect(previewKindOf('', '<!DOCTYPE html><html>'), PreviewKind.html);
    expect(previewKindOf('dart', 'void main'), isNull);
    final doc = previewDocument(PreviewKind.mermaid, 'A-->B<C', dark: true);
    expect(doc, contains('A--&gt;B&lt;C'));
    expect(doc, contains("theme:'dark'"));
  });

  test('快捷入口链接解析', () {
    expect(QuickEntry.fromUri(Uri.parse('xcagent://new')), isA<NewChatEntry>());
    final ask = QuickEntry.fromUri(
      Uri.parse('xcagent://ask?text=%E4%BD%A0%E5%A5%BD'),
    );
    expect((ask as NewChatEntry).text, '你好');
    expect(
      QuickEntry.fromUri(Uri.parse('xcagent://search')),
      isA<SearchEntry>(),
    );
    expect(QuickEntry.fromUri(Uri.parse('https://x.com')), isNull);
  });
}
