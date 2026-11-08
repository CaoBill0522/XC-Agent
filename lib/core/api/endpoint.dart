import 'protocol.dart';

/// Anthropic API 版本头。
const kAnthropicVersion = '2023-06-01';

/// DeepSeek 官方的 Anthropic 兼容接口（支持服务端 web_search 工具）。
const kDeepSeekAnthropicBase = 'https://api.deepseek.com/anthropic';

/// 可以通过 Responses 接口的 web_search 工具联网的模型：OpenAI 的 GPT / o 系列、
/// xAI 的 Grok。中转站常带厂商前缀（如 `openai/gpt-4o`），先去掉。
bool responsesSearchModel(String model) {
  var m = model.toLowerCase().trim();
  m = m.substring(m.lastIndexOf('/') + 1);
  if (!RegExp(r'^(gpt-|chatgpt-|o\d|grok-)').hasMatch(m)) return false;
  // 生图 / 语音 / 实时 / 嵌入模型不参与对话联网；*-search-* 模型在 Chat 接口自带联网。
  return !RegExp(r'image|audio|realtime|tts|transcribe|embedding|search')
      .hasMatch(m);
}

/// 用 OpenAI 格式接入、联网时可改走同地址 Responses 接口的渠道：OpenAI、xAI 官方和中转站。
const responsesSearchPresets = {'openai', 'xai', 'custom'};

/// 是否 DeepSeek 官方接口：DeepSeek 预设，或自定义渠道里填了官方地址。
bool isDeepSeekOfficial({required String presetId, required String baseUrl}) =>
    presetId == 'deepseek' || baseUrl.contains('api.deepseek.com');

/// 一个可直接发请求的渠道端点：协议 + 地址 + 鉴权。
///
/// Base URL 约定与各家官方 SDK 一致，用户照着厂商文档粘贴即可：
/// - OpenAI 系：base 含版本段，如 `https://api.openai.com/v1`、
///   `https://open.bigmodel.cn/api/paas/v4`。只填域名（无路径）时自动补 `/v1`。
/// - Anthropic 系：base 不含 `/v1`，如 `https://api.anthropic.com`、
///   `https://open.bigmodel.cn/api/anthropic`。误带 `/v1` 时自动去掉。
class ChannelEndpoint {
  ChannelEndpoint({
    required this.protocol,
    required String baseUrl,
    required this.apiKey,
    this.extraHeaders = const {},
  }) : baseUrl = normalizeBaseUrl(protocol, baseUrl);

  final ApiProtocol protocol;
  final String baseUrl;
  final String apiKey;
  final Map<String, String> extraHeaders;

  static String normalizeBaseUrl(ApiProtocol protocol, String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty) return url;
    if (!url.contains('://')) url = 'https://$url';

    final uri = Uri.tryParse(url);
    if (uri == null) return url;

    if (protocol.isOpenAI) {
      if (uri.path.isEmpty || uri.path == '/') url = '$url/v1';
    } else if (url.endsWith('/v1')) {
      url = url.substring(0, url.length - 3);
    }
    return url;
  }

  /// 拼接接口地址。[path] 以 `/` 开头。
  Uri url(String path) => Uri.parse('$baseUrl$path');

  Uri get modelsUrl => protocol.isOpenAI ? url('/models') : url('/v1/models');

  /// 发对话请求的地址（M1 用于连通性测试，M2 起用于正式请求）。
  Uri get chatUrl => switch (protocol) {
    ApiProtocol.openaiChat => url('/chat/completions'),
    ApiProtocol.openaiResponses => url('/responses'),
    ApiProtocol.anthropic => url('/v1/messages'),
  };

  Map<String, String> get headers => {
    if (protocol.isOpenAI) 'Authorization': 'Bearer $apiKey',
    if (!protocol.isOpenAI) ...{
      'x-api-key': apiKey,
      'anthropic-version': kAnthropicVersion,
    },
    ...extraHeaders,
  };

  /// 联网搜索时实际使用的端点（同一个 Key）：
  /// - DeepSeek 官方的 Chat Completions 不支持联网，改走 Anthropic 兼容接口；
  /// - OpenAI 格式下普通 GPT / Grok 模型只有 Responses 接口能联网，改走同地址的
  ///   Responses 接口（中转站不支持时由 ChatService 退回普通对话）。
  ChannelEndpoint forWebSearch({
    required String presetId,
    required String model,
  }) {
    if (protocol != ApiProtocol.openaiChat) return this;
    if (isDeepSeekOfficial(presetId: presetId, baseUrl: baseUrl)) {
      return _copy(ApiProtocol.anthropic, kDeepSeekAnthropicBase);
    }
    if (responsesSearchPresets.contains(presetId) &&
        responsesSearchModel(model)) {
      return _copy(ApiProtocol.openaiResponses, baseUrl);
    }
    return this;
  }

  ChannelEndpoint _copy(ApiProtocol protocol, String baseUrl) =>
      ChannelEndpoint(
        protocol: protocol,
        baseUrl: baseUrl,
        apiKey: apiKey,
        extraHeaders: extraHeaders,
      );
}
