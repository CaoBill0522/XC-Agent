import '../../chat/chat_types.dart';
import '../api_error.dart';
import '../endpoint.dart';
import '../protocol.dart';
import '../sse.dart';
import 'anthropic_adapter.dart';
import 'openai_chat_adapter.dart';
import 'openai_responses_adapter.dart';
import '../../../l10n/tr.dart';

/// 协议适配器：把通用的 [ChatRequest] 转成某种协议的请求体，并把该协议的流式响应解析成 [ChatEvent]。
abstract class ProtocolAdapter {
  const ProtocolAdapter();

  Map<String, dynamic> buildBody(ChatRequest req);

  /// 解析一个 SSE 事件，返回 0~n 个事件。遇到服务端错误时抛 [ApiException]。
  Iterable<ChatEvent> parseEvent(SseEvent e);

  /// 部分中转站忽略 stream:true，直接返回完整 JSON，这里兜底解析。
  Iterable<ChatEvent> parseFull(Map<String, dynamic> json);

  static ProtocolAdapter of(ApiProtocol p) => switch (p) {
    ApiProtocol.openaiChat => const OpenAIChatAdapter(),
    ApiProtocol.openaiResponses => const OpenAIResponsesAdapter(),
    ApiProtocol.anthropic => const AnthropicAdapter(),
  };
}

/// 某个渠道 + 模型组合是否支持原生联网搜索。
///
/// [baseUrl] 用于识别填了官方地址的自定义渠道（如 DeepSeek）。
bool supportsWebSearch({
  required ApiProtocol protocol,
  required String presetId,
  required String model,
  String baseUrl = '',
}) {
  final m = model.toLowerCase();
  // DeepSeek 官方（2026-10 起）：Anthropic 兼容接口支持服务端 web_search；
  // Chat Completions 不支持，但联网时会自动改走同 Key 的 Anthropic 兼容接口
  // （见 ChannelEndpoint.forWebSearch）；Responses 接口只有 v4-pro 支持。
  if (isDeepSeekOfficial(presetId: presetId, baseUrl: baseUrl)) {
    return protocol != ApiProtocol.openaiResponses || m.contains('v4-pro');
  }
  return switch (protocol) {
    // Responses API 的 web_search 工具（OpenAI、xAI）。
    ApiProtocol.openaiResponses => true,
    // Anthropic 服务端 web_search 工具；兼容层（如智谱）未必实现，按 Claude 模型名判断。
    ApiProtocol.anthropic => presetId == 'anthropic' || m.contains('claude'),
    // Chat Completions：智谱 tools.web_search；OpenAI 的 *-search-* 模型；
    // 普通 GPT / Grok 联网时改走同地址的 Responses 接口（见 ChannelEndpoint.forWebSearch）。
    ApiProtocol.openaiChat =>
      presetId == 'zhipu' ||
          m.contains('search') ||
          (responsesSearchPresets.contains(presetId) &&
              responsesSearchModel(model)),
  };
}

/// 抛出流中的错误对象（OpenAI: {error:{message}}；Anthropic: {type:error,error:{message}}）。
Never throwStreamError(Object? error) {
  String msg = tr('服务端返回错误');
  if (error is Map) {
    msg = (error['message'] ?? error['type'] ?? msg).toString();
  } else if (error is String) {
    msg = error;
  }
  throw ApiException(tr('请求失败'), detail: msg);
}

/// 从 data URL 里拆出 mime 和 base64。
({String mime, String base64})? splitDataUrl(String url) {
  final m = RegExp(r'^data:([^;]+);base64,(.*)$', dotAll: true).firstMatch(url);
  if (m == null) return null;
  return (mime: m.group(1)!, base64: m.group(2)!);
}
