/// 会话模式。[id] 存进 Conversations.mode，不要改。
enum ConversationMode {
  /// 一个模型回答。
  single('single', '单模型', '一个模型回答'),

  /// 同一问题同时发给多个模型，采纳其中一个回答。
  multi('multi', '多 Agent 并问', '同一个问题同时发给多个模型，采纳其中一个回答继续对话'),

  /// 按顺序接力：每个模型拿到原始问题和上一个模型的结果，最后一个的回答作为本轮结论。
  chain('chain', '接力分析', '按顺序依次分析：每个模型拿到原始问题和上一个模型的结果');

  const ConversationMode(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  /// 是否需要选多个参与者。
  bool get isGroup => this != single;

  static ConversationMode fromId(String? id, {int participants = 1}) {
    for (final m in values) {
      if (m.id == id) return m;
    }
    return participants > 1 ? multi : single;
  }
}

/// 接力分析中某一步发给模型的用户消息。
///
/// 第一步直接是原始问题；之后每一步 = 原始问题 + 上一步的结果。
String buildChainPrompt({
  required String question,
  required int step,
  String? previousLabel,
  String? previousOutput,
}) {
  if (step == 0 || previousOutput == null) return question;
  final q = question.trim().isEmpty ? '（见附图）' : question.trim();
  return '【原始问题】\n$q\n\n'
      '【上一步分析结果（第 $step 步 · ${previousLabel ?? '上一个模型'}）】\n'
      '${previousOutput.trim()}\n\n'
      '你是接力分析中的第 ${step + 1} 步。请结合原始问题和上一步的分析结果，'
      '继续深入分析：可以补充遗漏、指出并修正错误、完善结论，不必重复已经正确的内容。'
      '最后给出你的完整回答。';
}
