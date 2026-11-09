import 'dart:convert';

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
        j['name'] as String? ?? '文件',
        j['mime'] as String? ?? 'application/octet-stream',
        (j['size'] as num?)?.toInt() ?? 0,
      ),
      'context' => ContextPart(j['text'] as String? ?? ''),
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

extension ContentPartsX on List<ContentPart> {
  String get text => whereType<TextPart>().map((p) => p.text).join();
  String get thinking => whereType<ThinkingPart>().map((p) => p.text).join();
  List<ImagePart> get images => whereType<ImagePart>().toList();
  List<CitationPart> get citations => whereType<CitationPart>().toList();
  List<NoticePart> get notices => whereType<NoticePart>().toList();
  List<FilePart> get files => whereType<FilePart>().toList();
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
      b.write('【背景：之前对话的总结】\n$ctx\n\n');
    }
    if (q != null && q.isNotEmpty) {
      b.write('【我想追问的内容】\n');
      b.write(q.split('\n').map((l) => '> $l').join('\n'));
      b.write('\n\n');
    }
    b.write(question.isEmpty ? '请解释一下上面这段内容。' : question);
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
  });

  /// user / assistant
  final String role;
  final String text;
  final List<InlineImage> images;

  /// 原样发送给模型的文件（目前是 PDF）；文本类文件已并入 [text]。
  final List<InlineFile> files;
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

  const ReasoningEffort(this.id, this.label);
  final String id;
  final String label;

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
  });

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
