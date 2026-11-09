import 'dart:convert';

import '../../chat/chat_types.dart';
import '../sse.dart';
import 'adapter.dart';

/// Anthropic Messages API（及智谱等兼容实现）。
class AnthropicAdapter extends ProtocolAdapter {
  const AnthropicAdapter();

  /// Anthropic 要求必须传 max_tokens。
  static const defaultMaxTokens = 8192;

  static const _thinkingBudget = {
    ReasoningEffort.low: 2048,
    ReasoningEffort.medium: 8192,
    ReasoningEffort.high: 24576,
  };

  @override
  Map<String, dynamic> buildBody(ChatRequest req) {
    // 相邻同角色消息合并（Anthropic 要求 user / assistant 交替）。
    final messages = <Map<String, dynamic>>[];
    for (final t in req.turns) {
      final role = t.role == 'tool' ? 'user' : t.role;
      final blocks = <Map<String, dynamic>>[
        // 开启思考时调用工具：本轮带签名的思考块必须原样放回。
        if (t.thinkingSignature case final sig?)
          {'type': 'thinking', 'thinking': t.thinking ?? '', 'signature': sig},
        for (final r in t.toolResults)
          {
            'type': 'tool_result',
            'tool_use_id': r.callId,
            'content': r.content,
            if (r.isError) 'is_error': true,
          },
        for (final img in t.images)
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': img.mime,
              'data': img.base64,
            },
          },
        for (final f in t.files)
          {
            'type': 'document',
            'source': {
              'type': 'base64',
              'media_type': f.mime,
              'data': f.base64,
            },
            'title': f.name,
          },
        if (t.text.isNotEmpty) {'type': 'text', 'text': t.text},
        for (final c in t.toolCalls)
          {
            'type': 'tool_use',
            'id': c.id,
            'name': c.name,
            'input': c.argumentsMap,
          },
      ];
      if (blocks.isEmpty) continue;
      if (messages.isNotEmpty && messages.last['role'] == role) {
        (messages.last['content'] as List).addAll(blocks);
      } else {
        messages.add({'role': role, 'content': blocks});
      }
    }

    final budget = req.reasoningCapable
        ? _thinkingBudget[req.params.reasoning]
        : null;
    final baseMax = req.params.maxTokens ?? defaultMaxTokens;
    return {
      'model': req.model,
      'max_tokens': budget == null ? baseMax : budget + baseMax,
      'stream': true,
      if (req.system case final s? when s.trim().isNotEmpty) 'system': s,
      'messages': messages,
      // 开启 thinking 时不能自定义 temperature。
      if (budget == null) 'temperature': ?req.params.temperature,
      if (budget != null)
        'thinking': {'type': 'enabled', 'budget_tokens': budget},
      if (req.webSearch || req.tools.isNotEmpty)
        'tools': [
          if (req.webSearch)
            {
              'type': 'web_search_20250305',
              'name': 'web_search',
              'max_uses': 5,
            },
          for (final t in req.tools)
            {
              'name': t.name,
              'description': t.description,
              'input_schema': t.parameters,
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

    switch (json['type'] ?? e.event) {
      case 'message_start':
        final u = (json['message'] as Map?)?['usage'] as Map?;
        if (u != null) {
          yield UsageEvent(input: (u['input_tokens'] as num?)?.toInt());
        }
      case 'content_block_start':
        yield* _block(
          json['content_block'],
          index: (json['index'] as num?)?.toInt() ?? 0,
          streaming: true,
        );
      case 'content_block_delta':
        final d = json['delta'] as Map?;
        switch (d?['type']) {
          case 'text_delta':
            yield TextDelta(d!['text'] as String);
          case 'thinking_delta':
            yield ThinkingDelta(d!['thinking'] as String);
          case 'input_json_delta':
            yield ToolCallDelta(
              index: (json['index'] as num?)?.toInt() ?? 0,
              arguments: d!['partial_json'] as String? ?? '',
            );
          case 'signature_delta':
            if (d!['signature'] case final String sig) {
              yield ThinkingSignatureEvent(sig);
            }
          case 'citations_delta':
            final c = d!['citation'] as Map?;
            if (c?['url'] case final String url) {
              yield CitationEvent(url, c!['title'] as String?);
            }
        }
      case 'message_delta':
        final u = json['usage'] as Map?;
        if (u != null) {
          yield UsageEvent(output: (u['output_tokens'] as num?)?.toInt());
        }
      case 'error':
        throwStreamError(json['error']);
    }
  }

  /// [streaming] 时 tool_use 的参数随后由 input_json_delta 分段给出。
  Iterable<ChatEvent> _block(
    Object? block, {
    int index = 0,
    bool streaming = false,
  }) sync* {
    if (block is! Map) return;
    switch (block['type']) {
      case 'tool_use':
        final input = block['input'];
        yield ToolCallDelta(
          index: index,
          id: block['id'] as String?,
          name: block['name'] as String?,
          arguments: streaming || input == null ? '' : jsonEncode(input),
        );
      case 'text':
        if (block['text'] case final String t when t.isNotEmpty) {
          yield TextDelta(t);
        }
      case 'thinking':
        if (block['thinking'] case final String t when t.isNotEmpty) {
          yield ThinkingDelta(t);
        }
        if (block['signature'] case final String sig when sig.isNotEmpty) {
          yield ThinkingSignatureEvent(sig);
        }
      case 'web_search_tool_result':
        for (final r
            in (block['content'] is List
                ? block['content'] as List
                : const [])) {
          if (r is Map && r['url'] is String) {
            yield CitationEvent(r['url'] as String, r['title'] as String?);
          }
        }
    }
  }

  @override
  Iterable<ChatEvent> parseFull(Map<String, dynamic> json) sync* {
    if (json['type'] == 'error') throwStreamError(json['error']);
    for (final (i, b) in (json['content'] as List? ?? const []).indexed) {
      yield* _block(b, index: i);
    }
    if (json['usage'] case final Map u) {
      yield UsageEvent(
        input: (u['input_tokens'] as num?)?.toInt(),
        output: (u['output_tokens'] as num?)?.toInt(),
      );
    }
  }
}
