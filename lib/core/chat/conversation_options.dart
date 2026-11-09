import 'dart:convert';

import 'participant.dart';

/// 会话选项，存进 Conversations.optionsJson。键名是存储格式，不要改。
class ConversationOptions {
  const ConversationOptions({
    this.judge,
    this.rounds = 2,
    this.contextTurns,
    this.autoCompress = false,
    this.memory,
  });

  /// 裁判模式的裁判；辩论模式的总结者（为空时由第一位辩手总结）。
  final Participant? judge;

  /// 辩论轮数（每轮每位辩手各发言一次）。
  final int rounds;

  /// 每次请求只携带最近 N 轮对话；null = 全部。
  final int? contextTurns;

  /// 上下文过长时自动把早期对话压缩成摘要。
  final bool autoCompress;

  /// 已压缩的早期对话摘要。
  final ContextMemory? memory;

  static const roundChoices = [1, 2, 3];
  static const contextChoices = <int?>[null, 20, 10, 5, 3];

  ConversationOptions copyWith({
    Participant? Function()? judge,
    int? rounds,
    int? Function()? contextTurns,
    bool? autoCompress,
    ContextMemory? Function()? memory,
  }) => ConversationOptions(
    judge: judge == null ? this.judge : judge(),
    rounds: rounds ?? this.rounds,
    contextTurns: contextTurns == null ? this.contextTurns : contextTurns(),
    autoCompress: autoCompress ?? this.autoCompress,
    memory: memory == null ? this.memory : memory(),
  );

  Map<String, dynamic> toJson() => {
    if (judge != null) 'judge': judge!.toJson(),
    'rounds': rounds,
    'contextTurns': ?contextTurns,
    if (autoCompress) 'autoCompress': true,
    if (memory != null) 'memory': memory!.toJson(),
  };

  String encode() => jsonEncode(toJson());

  static ConversationOptions decode(String? json) {
    try {
      final j = jsonDecode(json ?? '{}') as Map<String, dynamic>;
      return ConversationOptions(
        judge: j['judge'] is Map<String, dynamic>
            ? Participant.fromJson(j['judge'] as Map<String, dynamic>)
            : null,
        rounds: ((j['rounds'] as num?)?.toInt() ?? 2).clamp(1, 5),
        contextTurns: (j['contextTurns'] as num?)?.toInt(),
        autoCompress: j['autoCompress'] == true,
        memory: j['memory'] is Map<String, dynamic>
            ? ContextMemory.fromJson(j['memory'] as Map<String, dynamic>)
            : null,
      );
    } catch (_) {
      return const ConversationOptions();
    }
  }
}

/// 早期对话的压缩摘要：[untilMessageId] 及之前的消息不再原样发送，用 [summary] 代替。
class ContextMemory {
  const ContextMemory({required this.summary, required this.untilMessageId});

  final String summary;
  final String untilMessageId;

  Map<String, dynamic> toJson() => {
    'summary': summary,
    'until': untilMessageId,
  };

  factory ContextMemory.fromJson(Map<String, dynamic> j) => ContextMemory(
    summary: j['summary'] as String? ?? '',
    untilMessageId: j['until'] as String? ?? '',
  );
}

/// 粗略估算 token 数：中日韩字符约 1 字 1 token，其余约 4 个字符 1 token。
int estimateTokens(String text) {
  var cjk = 0;
  for (final r in text.runes) {
    if ((r >= 0x3000 && r <= 0x9FFF) ||
        (r >= 0xAC00 && r <= 0xD7AF) ||
        (r >= 0xF900 && r <= 0xFAFF) ||
        (r >= 0xFF00 && r <= 0xFFEF)) {
      cjk++;
    }
  }
  return cjk + ((text.length - cjk) / 4).ceil();
}
