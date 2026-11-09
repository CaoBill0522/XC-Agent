import 'dart:convert';

import '../../l10n/tr.dart';

/// 消息内容块，存进 Messages.partsJson。`type` 字段是存储格式，不要改。
sealed class ContentPart {
  const ContentPart();

  Map<String, dynamic> toJson();

  static ContentPart? fromJson(Map<String, dynamic> j) {
    return switch (j['type']) {
      'text' => TextPart(j['text'] as String? ?? ''),
      'thinking' => ThinkingPart(j['text'] as String? ?? ''),
      'image' => ImagePart(
        j['path'] as String,
        j['mime'] as String? ?? 'image/png',
      ),
      'citation' => CitationPart(j['url'] as String, j['title'] as String?),
      'notice' => NoticePart(j['text'] as String? ?? ''),
      'quote' => QuotePart(j['text'] as String? ?? ''),
      'file' => FilePart(
        j['path'] as String,
        j['name'] as String? ?? tr('文件'),
        j['mime'] as String? ?? 'application/octet-stream',
        (j['size'] as num?)?.toInt() ?? 0,
      ),
      'context' => ContextPart(j['text'] as String? ?? ''),
      'tool' => ToolCallPart(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        label: j['label'] as String?,
        arguments: j['args'] as String? ?? '{}',
        result: j['result'] as String?,
        isError: j['error'] == true,
      ),
      _ => null,
    };
  }

  static List<ContentPart> decodeList(String json) {
    try {
      return [
        for (final p in jsonDecode(json) as List)
          if (p is Map<String, dynamic>) ?fromJson(p),
      ];
    } catch (_) {
      return const [];
    }
  }

  static String encodeList(List<ContentPart> parts) =>
      jsonEncode([for (final p in parts) p.toJson()]);
}

class TextPart extends ContentPart {
  const TextPart(this.text);
  final String text;
  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class ThinkingPart extends ContentPart {
  const ThinkingPart(this.text);
  final String text;
  @override
  Map<String, dynamic> toJson() => {'type': 'thinking', 'text': text};
}

/// 图片：[path] 是相对图片目录的文件名（见 ImageStore）。
class ImagePart extends ContentPart {
  const ImagePart(this.path, this.mime);
  final String path;
  final String mime;
  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'path': path,
    'mime': mime,
  };
}

class CitationPart extends ContentPart {
  const CitationPart(this.url, this.title);
  final String url;
  final String? title;
  @override
  Map<String, dynamic> toJson() => {
    'type': 'citation',
    'url': url,
    'title': ?title,
  };
}

/// 给用户看的提示（如「该渠道不支持联网搜索，已按普通对话回答」），不进上下文。
class NoticePart extends ContentPart {
  const NoticePart(this.text);
  final String text;
  @override
  Map<String, dynamic> toJson() => {'type': 'notice', 'text': text};
}

/// 附件文件：[path] 是相对附件目录的文件名（见 ImageStore）。
class FilePart extends ContentPart {
  const FilePart(this.path, this.name, this.mime, this.size);
  final String path;
  final String name;
  final String mime;
  final int size;

  bool get isPdf => mime == 'application/pdf';

  @override
  Map<String, dynamic> toJson() => {
    'type': 'file',
    'path': path,
    'name': name,
    'mime': mime,
    'size': size,
  };
}

/// 用户追问时引用的回答片段（选中的文字）。
class QuotePart extends ContentPart {
  const QuotePart(this.text);
  final String text;
  @override
  Map<String, dynamic> toJson() => {'type': 'quote', 'text': text};
}

/// 「新对话追问」时由原 Agent 生成的前文总结，作为新对话的背景。
class ContextPart extends ContentPart {
  const ContextPart(this.text);
  final String text;
  @override
  Map<String, dynamic> toJson() => {'type': 'context', 'text': text};
}

/// 回答过程中的一次工具调用（参数和结果），只用于展示，不进后续上下文。
class ToolCallPart extends ContentPart {
  const ToolCallPart({
    required this.id,
    required this.name,
    required this.arguments,
    this.label,
    this.result,
    this.isError = false,
  });

  final String id;

  /// 发给模型的工具名。
  final String name;

  /// 给用户看的名字（如「读取网页」）。
  final String? label;

  /// 参数 JSON。
  final String arguments;

  /// 结果；null 表示还在执行。
  final String? result;
  final bool isError;

  bool get running => result == null;

  ToolCallPart withResult(String result, {bool isError = false}) =>
      ToolCallPart(
        id: id,
        name: name,
        label: label,
        arguments: arguments,
        result: result,
        isError: isError,
      );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'tool',
    'id': id,
    'name': name,
    'label': ?label,
    'args': arguments,
    'result': ?result,
    if (isError) 'error': true,
  };
}

extension ContentPartsX on List<ContentPart> {
  String get text => whereType<TextPart>().map((p) => p.text).join();
  String get thinking => whereType<ThinkingPart>().map((p) => p.text).join();
  List<ImagePart> get images => whereType<ImagePart>().toList();
  List<CitationPart> get citations => whereType<CitationPart>().toList();
  List<NoticePart> get notices => whereType<NoticePart>().toList();
  List<FilePart> get files => whereType<FilePart>().toList();
  List<ToolCallPart> get toolCalls => whereType<ToolCallPart>().toList();
  String? get quote => whereType<QuotePart>().firstOrNull?.text;
  String? get contextSummary => whereType<ContextPart>().firstOrNull?.text;

  /// 用户消息实际发给模型的文字：背景总结、引用片段和问题拼在一起。
  String get promptText {
    final question = text.trim();
    final ctx = contextSummary?.trim();
    final q = quote?.trim();
    if ((ctx == null || ctx.isEmpty) && (q == null || q.isEmpty)) {
      return question;
    }
    final b = StringBuffer();
    if (ctx != null && ctx.isNotEmpty) {
      b.write(trArgs('【背景：之前对话的总结】\n{0}\n\n', [ctx]));
    }
    if (q != null && q.isNotEmpty) {
      b.write(tr('【我想追问的内容】\n'));
      b.write(q.split('\n').map((l) => '> $l').join('\n'));
      b.write('\n\n');
    }
    b.write(question.isEmpty ? tr('请解释一下上面这段内容。') : question);
    return b.toString();
  }
}

/// 发给模型的一轮对话（已从数据库消息转换，图片已读成 base64）。
class ChatTurn {
  const ChatTurn({
    required this.role,
    required this.text,
    this.images = const [],
    this.files = const [],
    this.toolCalls = const [],
    this.toolResults = const [],
    this.thinking,
    this.thinkingSignature,
  });

  /// user / assistant / tool（工具执行结果，只出现在一次回答的工具调用循环里）
  final String role;
  final String text;
  final List<InlineImage> images;

  /// 原样发送给模型的文件（目前是 PDF）；文本类文件已并入 [text]。
  final List<InlineFile> files;

  /// assistant：本轮模型要求调用的工具。
  final List<ToolCall> toolCalls;

  /// tool：工具执行结果。
  final List<ToolResult> toolResults;

  /// assistant：本轮的思考内容和签名（Anthropic 开启思考时调用工具，
  /// 下一轮必须原样带回带签名的思考块）。
  final String? thinking;
  final String? thinkingSignature;
}

/// 提供给模型的工具定义（JSON Schema 参数）。
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

/// 模型发起的一次工具调用。
class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;

  /// 参数 JSON 字符串。
  final String arguments;

  Map<String, dynamic> get argumentsMap {
    try {
      final j = jsonDecode(arguments.isEmpty ? '{}' : arguments);
      return j is Map<String, dynamic> ? j : {};
    } catch (_) {
      return {};
    }
  }
}

class ToolResult {
  const ToolResult({
    required this.callId,
    required this.name,
    required this.content,
    this.isError = false,
  });

  final String callId;
  final String name;
  final String content;
  final bool isError;
}

class InlineFile {
  const InlineFile({
    required this.name,
    required this.mime,
    required this.base64,
  });
  final String name;
  final String mime;
  final String base64;

  String get dataUrl => 'data:$mime;base64,$base64';
}

class InlineImage {
  const InlineImage({required this.base64, required this.mime});
  final String base64;
  final String mime;

  String get dataUrl => 'data:$mime;base64,$base64';
}

/// 推理强度。auto = 不传参数，由厂商默认决定。
enum ReasoningEffort {
  auto('auto', '默认'),
  off('off', '关闭'),
  low('low', '低'),
  medium('medium', '中'),
  high('high', '高');

  const ReasoningEffort(this.id, this._label);
  final String id;
  final String _label;
  String get label => tr(_label);

  static ReasoningEffort fromId(String? id) =>
      values.firstWhere((e) => e.id == id, orElse: () => auto);
}

/// 生成参数（来自助手设置）。null 表示不传，用厂商默认值。
class GenParams {
  const GenParams({
    this.temperature,
    this.maxTokens,
    this.reasoning = ReasoningEffort.auto,
  });

  final double? temperature;
  final int? maxTokens;
  final ReasoningEffort reasoning;

  factory GenParams.fromJson(String json) {
    try {
      final j = jsonDecode(json) as Map<String, dynamic>;
      return GenParams(
        temperature: (j['temperature'] as num?)?.toDouble(),
        maxTokens: (j['max_tokens'] as num?)?.toInt(),
        reasoning: ReasoningEffort.fromId(j['reasoning'] as String?),
      );
    } catch (_) {
      return const GenParams();
    }
  }

  String toJson() => jsonEncode({
    'temperature': ?temperature,
    'max_tokens': ?maxTokens,
    'reasoning': reasoning.id,
  });
}

/// 一次对话请求（与协议无关）。
class ChatRequest {
  const ChatRequest({
    required this.model,
    required this.turns,
    this.system,
    this.params = const GenParams(),
    this.webSearch = false,
    this.reasoningCapable = false,
    this.presetId = 'custom',
    this.tools = const [],
  });

  ChatRequest copyWith({List<ChatTurn>? turns, List<ToolSpec>? tools}) =>
      ChatRequest(
        model: model,
        turns: turns ?? this.turns,
        system: system,
        params: params,
        webSearch: webSearch,
        reasoningCapable: reasoningCapable,
        presetId: presetId,
        tools: tools ?? this.tools,
      );

  /// 上游模型名。
  final String model;
  final List<ChatTurn> turns;
  final String? system;
  final GenParams params;
  final bool webSearch;

  /// 模型带「推理」能力标签时才发送推理相关参数，避免普通模型报错。
  final bool reasoningCapable;

  /// 渠道预设，用于厂商特有参数（如智谱的联网工具）。
  final String presetId;

  /// 可调用的函数工具。
  final List<ToolSpec> tools;
}

/// 流式输出事件。
sealed class ChatEvent {
  const ChatEvent();
}

class TextDelta extends ChatEvent {
  const TextDelta(this.text);
  final String text;
}

class ThinkingDelta extends ChatEvent {
  const ThinkingDelta(this.text);
  final String text;
}

class CitationEvent extends ChatEvent {
  const CitationEvent(this.url, this.title);
  final String url;
  final String? title;
}

/// 模型直接输出的图片（base64）。
class ImageEvent extends ChatEvent {
  const ImageEvent(this.base64, this.mime);
  final String base64;
  final String mime;
}

/// 工具调用片段：同一 [index] 的片段拼成一次完整调用（OpenAI Chat 流式时
/// 参数是一段段来的；Responses / Anthropic 一次给全或按块给）。
class ToolCallDelta extends ChatEvent {
  const ToolCallDelta({
    required this.index,
    this.id,
    this.name,
    this.arguments = '',
  });
  final int index;
  final String? id;
  final String? name;
  final String arguments;
}

/// Anthropic 思考块的签名。
class ThinkingSignatureEvent extends ChatEvent {
  const ThinkingSignatureEvent(this.signature);
  final String signature;
}

class UsageEvent extends ChatEvent {
  const UsageEvent({this.input, this.output});
  final int? input;
  final int? output;
}

/// Messages.kind 的取值。存储格式，不要改。
abstract final class MsgKind {
  static const judge = 'judge';
  static const debate = 'debate';
  static const summary = 'summary';
}
