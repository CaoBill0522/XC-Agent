import 'dart:convert';

import '../../chat/chat_types.dart';
import '../sse.dart';
import 'adapter.dart';

/// OpenAI Responses API（OpenAI、xAI）。
class OpenAIResponsesAdapter extends ProtocolAdapter {
  const OpenAIResponsesAdapter();

  @override
  Map<String, dynamic> buildBody(ChatRequest req) {
    final input = [
      for (final t in req.turns)
        if (t.role == 'tool')
          for (final r in t.toolResults)
            {
              'type': 'function_call_output',
              'call_id': r.callId,
              'output': r.content,
            }
        else ...[
          if (t.role != 'assistant' || t.text.isNotEmpty)
            {
              'role': t.role,
              'content': t.role == 'assistant'
                  ? [
                      {'type': 'output_text', 'text': t.text},
                    ]
                  : [
                      if (t.text.isNotEmpty)
                        {'type': 'input_text', 'text': t.text},
                      for (final img in t.images)
                        {'type': 'input_image', 'image_url': img.dataUrl},
                      for (final f in t.files)
                        {
                          'type': 'input_file',
                          'filename': f.name,
                          'file_data': f.dataUrl,
                        },
                    ],
            },
          for (final c in t.toolCalls)
            {
              'type': 'function_call',
              'call_id': c.id,
              'name': c.name,
              'arguments': c.arguments,
            },
        ],
    ];
    final effort = req.params.reasoning;
    // 默认强度下只对 OpenAI 官方请求推理摘要；兼容实现（如 xAI）未必接受该参数。
    final reasoningOn =
        req.reasoningCapable &&
        effort != ReasoningEffort.off &&
        (effort != ReasoningEffort.auto || req.presetId == 'openai');
    return {
      'model': req.model,
      'input': input,
      'stream': true,
      'store': false,
      if (req.system case final s? when s.trim().isNotEmpty) 'instructions': s,
      'temperature': ?req.params.temperature,
      'max_output_tokens': ?req.params.maxTokens,
      if (reasoningOn)
        'reasoning': {
          if (effort != ReasoningEffort.auto) 'effort': effort.id,
          'summary': 'auto',
        },
      if (req.webSearch || req.tools.isNotEmpty)
        'tools': [
          if (req.webSearch) {'type': 'web_search'},
          for (final t in req.tools)
            {
              'type': 'function',
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
        ],
    };
  }

  @override
  Iterable<ChatEvent> parseEvent(SseEvent e) sync* {
    final Object? json;
    try {
      json = jsonDecode(e.data);
    } catch (_) {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    final type = (json['type'] ?? e.event) as String?;

    switch (type) {
      case 'response.output_text.delta':
        if (json['delta'] case final String d) yield TextDelta(d);
      case 'response.reasoning_summary_text.delta' ||
          'response.reasoning_text.delta':
        if (json['delta'] case final String d) yield ThinkingDelta(d);
      case 'response.reasoning_summary_part.done':
        yield const ThinkingDelta('\n\n');
      case 'response.output_text.annotation.added':
        final a = json['annotation'];
        if (a is Map && a['url'] is String) {
          yield CitationEvent(a['url'] as String, a['title'] as String?);
        }
      case 'response.output_item.done':
        final item = json['item'];
        if (item is Map &&
            item['type'] == 'image_generation_call' &&
            item['result'] is String) {
          yield ImageEvent(item['result'] as String, 'image/png');
        }
        if (item is Map && item['type'] == 'function_call') {
          yield _call(item, (json['output_index'] as num?)?.toInt() ?? 0);
        }
      case 'response.completed':
        if (json['response'] case final Map r) yield* _usage(r);
      case 'response.failed' || 'response.incomplete':
        final r = json['response'];
        final err = (r is Map) ? r['error'] ?? r['incomplete_details'] : null;
        if (type == 'response.failed' || err != null) {
          throwStreamError(err ?? '响应未完成');
        }
      case 'error':
        throwStreamError(json['error'] ?? json['message'] ?? json);
    }
  }

  @override
  Iterable<ChatEvent> parseFull(Map<String, dynamic> json) sync* {
    if (json['error'] case final err?) throwStreamError(err);
    for (final (i, item) in (json['output'] as List? ?? const []).indexed) {
      if (item is! Map) continue;
      if (item['type'] == 'reasoning') {
        for (final s in (item['summary'] as List? ?? const [])) {
          if (s is Map && s['text'] is String) {
            yield ThinkingDelta(s['text'] as String);
          }
        }
      } else if (item['type'] == 'message') {
        for (final c in (item['content'] as List? ?? const [])) {
          if (c is! Map) continue;
          if (c['text'] is String) yield TextDelta(c['text'] as String);
          for (final a in (c['annotations'] as List? ?? const [])) {
            if (a is Map && a['url'] is String) {
              yield CitationEvent(a['url'] as String, a['title'] as String?);
            }
          }
        }
      } else if (item['type'] == 'image_generation_call' &&
          item['result'] is String) {
        yield ImageEvent(item['result'] as String, 'image/png');
      } else if (item['type'] == 'function_call') {
        yield _call(item, i);
      }
    }
    yield* _usage(json);
  }

  static ToolCallDelta _call(Map item, int index) => ToolCallDelta(
    index: index,
    id: (item['call_id'] ?? item['id']) as String?,
    name: item['name'] as String?,
    arguments: item['arguments'] as String? ?? '',
  );

  Iterable<ChatEvent> _usage(Map r) sync* {
    if (r['usage'] case final Map u) {
      yield UsageEvent(
        input: (u['input_tokens'] as num?)?.toInt(),
        output: (u['output_tokens'] as num?)?.toInt(),
      );
    }
  }
}
