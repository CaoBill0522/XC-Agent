import 'dart:convert';

/// 模型能力标签。[id] 存进数据库（Models.capabilitiesJson），不要改。
enum ModelCapability {
  vision('vision', '识图'),
  imageGen('image_gen', '生图'),
  reasoning('reasoning', '推理'),
  webSearch('web_search', '联网');

  const ModelCapability(this.id, this.label);

  final String id;
  final String label;

  static ModelCapability? fromId(String id) {
    for (final c in values) {
      if (c.id == id) return c;
    }
    return null;
  }

  static Set<ModelCapability> decode(String json) {
    try {
      return {for (final id in jsonDecode(json) as List) ?fromId(id as String)};
    } catch (_) {
      return {};
    }
  }

  static String encode(Set<ModelCapability> caps) => jsonEncode([
    for (final c in values)
      if (caps.contains(c)) c.id,
  ]);
}

/// 模型大类。拉取列表时，非 chat / image 的模型默认不勾选。
enum ModelKind { chat, image, embedding, audio, other }

class ModelProfile {
  const ModelProfile(this.kind, this.capabilities);

  final ModelKind kind;
  final Set<ModelCapability> capabilities;

  /// 拉取后是否默认勾选。
  bool get selectedByDefault =>
      kind == ModelKind.chat || kind == ModelKind.image;
}

/// 按模型名推断类型和能力。只是默认值，用户可在模型设置里手动修改。
///
/// 规则偏保守：宁可漏标（用户手动打开），不乱标（发图片给不支持的模型会直接报错）。
ModelProfile inferModelProfile(String modelId) {
  // 去掉中转站常见的厂商前缀，如 `openai/gpt-4o`、`anthropic/claude-...`。
  final full = modelId.toLowerCase().trim();
  final id = full.contains('/')
      ? full.substring(full.lastIndexOf('/') + 1)
      : full;

  bool has(String s) => id.contains(s);
  bool any(List<String> xs) => xs.any(id.contains);
  bool starts(List<String> xs) => xs.any(id.startsWith);

  // ---------- 类型 ----------
  if (any(['embed', 'bge-', 'text-similarity'])) {
    return const ModelProfile(ModelKind.embedding, {});
  }
  if (any(['rerank', 'moderation'])) {
    return const ModelProfile(ModelKind.other, {});
  }
  if (any(['whisper', 'tts', 'transcribe', 'realtime', 'speech']) ||
      (has('audio') && !has('gpt-4o-audio'))) {
    return const ModelProfile(ModelKind.audio, {});
  }

  // 纯生图模型：走图片生成接口，不能对话。
  final pureImageGen =
      any([
        'dall-e',
        'gpt-image',
        'cogview',
        'imagen',
        'flux',
        'stable-diffusion',
        'sdxl',
        'midjourney',
        'seedream',
        'grok-imagine',
      ]) ||
      RegExp(r'grok-\d.*-image').hasMatch(id);
  if (pureImageGen) {
    return ModelProfile(ModelKind.image, {
      ModelCapability.imageGen,
      // gpt-image 支持以图改图。
      if (has('gpt-image')) ModelCapability.vision,
    });
  }

  // 会出图的对话模型，如 gemini-2.5-flash-image。
  final chatImageGen = RegExp(r'-image(-preview|-generation)?$').hasMatch(id);

  final caps = <ModelCapability>{};
  if (chatImageGen) caps.add(ModelCapability.imageGen);

  // ---------- 识图 ----------
  final vision =
      any([
        'vision',
        '-vl',
        'vl-',
        'llava',
        'pixtral',
        '4o',
        'gpt-4.1',
        'gpt-4.5',
        'gpt-4-turbo',
        'gemini',
        'grok-4',
      ]) ||
      starts(['gpt-5', 'o3', 'o4']) ||
      (id.startsWith('o1') && !has('mini') && !has('preview')) ||
      // claude-3 起全系支持图片输入；排除 claude-2 / claude-instant。
      (id.startsWith('claude') && !any(['claude-2', 'claude-instant'])) ||
      RegExp(r'^glm-[\d.]+v').hasMatch(id) ||
      chatImageGen;
  if (vision) caps.add(ModelCapability.vision);

  // ---------- 推理 ----------
  final reasoning =
      any(['reasoner', 'thinking', 'qwq', '-r1', 'r1-']) ||
      id == 'r1' ||
      starts(['o1', 'o3', 'o4', 'gpt-5', 'grok-4', 'grok-3-mini']) ||
      RegExp(r'claude-(3-7|(sonnet|opus|haiku)-[4-9])').hasMatch(id) ||
      RegExp(r'claude-[4-9]').hasMatch(id) ||
      RegExp(r'gemini-(2\.5|[3-9])').hasMatch(id) ||
      RegExp(r'^glm-(4\.[5-9]|[5-9])').hasMatch(id);
  if (reasoning) caps.add(ModelCapability.reasoning);

  // ---------- 联网（厂商原生搜索工具，M4 按协议细化） ----------
  final webSearch =
      has('search') ||
      starts(['gpt-4o', 'gpt-4.1', 'gpt-5', 'o3', 'o4', 'grok', 'glm']) ||
      RegExp(r'claude-(3-5|3-7|(sonnet|opus|haiku)-[4-9]|[4-9])').hasMatch(id);
  if (webSearch) caps.add(ModelCapability.webSearch);

  return ModelProfile(ModelKind.chat, caps);
}
