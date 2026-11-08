import 'dart:convert';

import '../../chat/chat_types.dart';
import '../sse.dart';
import 'adapter.dart';

/// OpenAI Chat Completions（含 DeepSeek / 智谱 / 各类中转站等兼容实现）。
class OpenAIChatAdapter extends ProtocolAdapter {
  const OpenAIChatAdapter();

  @override
  Map<String, dynamic> buildBody(ChatRequest req) {
    final messages = <Map<String, dynamic>>[
      if (req.system case final s? when s.trim().isNotEmpty)
        {'role': 'system', 'content': s},
      for (final t in req.turns)
        {
          'role': t.role,
          'content': t.images.isEmpty
              ? t.text
              : [
                  if (t.text.isNotEmpty) {'type': 'text', 'text': t.text},
                  for (final img in t.images)
                    {
                      'type': 'image_url',
                      'image_url': {'url': img.dataUrl},
                    },
                ],
        },
    ];

    final effort = req.params.reasoning;
    return {
      'model': req.model,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      'temperature': ?req.params.temperature,
      'max_tokens': ?req.params.maxTokens,
      if (req.reasoningCapable &&
          effort != ReasoningEffort.auto &&
          effort != ReasoningEffort.off)
        'reasoning_effort': effort.id,
      if (req.webSearch && req.presetId == 'zhipu')
        'tools': [
          {
            'type': 'web_search',
            'web_search': {'enable': true, 'search_result': true},
          },
        ],
      if (req.webSearch && req.presetId != 'zhipu')
        'web_search_options': <String, dynamic>{},
    };
  }

  @override
  Iterable<ChatEvent> parseEvent(SseEvent e) sync* {
    if (e.isDone) return;
    final Object? json;
    try {
      json = jsonDecode(e.data);
    } catch (_) {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    yield* _parseChunk(json, delta: true);
  }

  @override
  Iterable<ChatEvent> parseFull(Map<String, dynamic> json) =>
      _parseChunk(json, delta: false);

  Iterable<ChatEvent> _parseChunk(
    Map<String, dynamic> json, {
    required bool delta,
  }) sync* {
    if (json['error'] != null) throwStreamError(json['error']);

    // 智谱联网搜索结果。
    if (json['web_search'] case final List results) {
      for (final r in results) {
        if (r is Map && r['link'] is String) {
          yield CitationEvent(r['link'] as String, r['title'] as String?);
        }
      }
    }

    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty) {
      final choice = choices.first as Map<String, dynamic>;
      final d =
          (delta ? choice['delta'] : choice['message'])
              as Map<String, dynamic>?;
      if (d != null) {
        // 推理内容：DeepSeek / 智谱用 reasoning_content，OpenRouter 等用 reasoning。
        final reasoning = d['reasoning_content'] ?? d['reasoning'];
        if (reasoning is String && reasoning.isNotEmpty) {
          yield ThinkingDelta(reasoning);
        }

        final content = d['content'];
        if (content is String && content.isNotEmpty) {
          yield TextDelta(content);
        } else if (content is List) {
          for (final c in content) {
            if (c is Map && c['type'] == 'text' && c['text'] is String) {
              yield TextDelta(c['text'] as String);
            }
          }
        }

        // OpenRouter 等返回的图片：images: [{type: image_url, image_url: {url: data:...}}]
        if (d['images'] case final List imgs) {
          for (final img in imgs) {
            if (img case {'image_url': {'url': final String url}}) {
              if (splitDataUrl(url) case final p?) {
                yield ImageEvent(p.base64, p.mime);
              }
            }
          }
        }

        // OpenAI 搜索模型的引用。
        if (d['annotations'] case final List anns) {
          for (final a in anns) {
            final c = (a is Map) ? a['url_citation'] as Map? : null;
            if (c != null && c['url'] is String) {
              yield CitationEvent(c['url'] as String, c['title'] as String?);
            }
          }
        }
      }
    }

    if (json['usage'] case final Map u) {
      yield UsageEvent(
        input: (u['prompt_tokens'] as num?)?.toInt(),
        output: (u['completion_tokens'] as num?)?.toInt(),
      );
    }
  }
}
