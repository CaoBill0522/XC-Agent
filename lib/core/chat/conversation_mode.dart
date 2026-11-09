/// 会话模式。[id] 存进 Conversations.mode，不要改。
enum ConversationMode {
  /// 一个模型回答。
  single('single', '单模型', '一个模型回答'),

  /// 同一问题同时发给多个模型，采纳其中一个回答。
  multi('multi', '多 Agent 并问', '同一个问题同时发给多个模型，采纳其中一个回答继续对话'),

  /// 按顺序接力：每个模型拿到原始问题和上一个模型的结果，最后一个的回答作为本轮结论。
  chain('chain', '接力分析', '按顺序依次分析：每个模型拿到原始问题和上一个模型的结果'),

  /// 多个模型各自回答，再由裁判对比打分并给出综合答案（作为本轮结论）。
  judge('judge', '裁判评分', '多个模型各自回答，再由一个裁判模型对比打分并给出综合答案'),

  /// 辩手轮流发言、反驳对方若干轮，最后由总结者给出结论。
  debate('debate', '辩论', '两个或多个模型轮流反驳对方几轮，最后总结出结论');

  const ConversationMode(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  /// 是否需要选多个参与者。
  bool get isGroup => this != single;

  /// 是否按步骤依次生成（接力、辩论）。
  bool get isSequential => this == chain || this == debate;

  /// 是否需要额外选择裁判 / 总结者。
  bool get hasJudge => this == judge || this == debate;

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

/// 裁判请求：原始问题 + 各模型的回答。
String buildJudgePrompt({
  required String question,
  required List<(String label, String answer)> answers,
}) {
  final q = question.trim().isEmpty ? '（见附图）' : question.trim();
  final b = StringBuffer('【原始问题】\n$q\n\n');
  for (final (i, (label, answer)) in answers.indexed) {
    b.write('【回答 ${i + 1}：$label】\n${answer.trim()}\n\n');
  }
  b.write(
    '你是裁判。请逐一评价以上回答：指出各自正确与错误的地方、遗漏和亮点，'
    '给每个回答打分（10 分制），说明最好的是哪一个及原因。'
    '最后另起一节「综合答案」，取各家所长给出你认为最准确完整的回答。',
  );
  return b.toString();
}

/// 辩论中某一次发言（或最后的总结）发给模型的用户消息。
String buildDebatePrompt({
  required String question,
  required List<(String label, String speech)> transcript,
  required String speaker,
  required int round,
  required int rounds,
  required bool summary,
}) {
  final q = question.trim().isEmpty ? '（见附图）' : question.trim();
  final b = StringBuffer('【辩题】\n$q\n\n');
  if (transcript.isNotEmpty) {
    b.write('【目前的发言】\n');
    for (final (label, speech) in transcript) {
      b.write('—— $label ——\n${speech.trim()}\n\n');
    }
  }
  if (summary) {
    b.write(
      '你是这场辩论的总结者。请客观梳理各方的主要论点和反驳，'
      '指出哪些观点站得住、哪些被驳倒，最后给出你的结论。',
    );
  } else if (transcript.isEmpty) {
    b.write('你是辩手「$speaker」，请先就这个问题给出你的观点和理由。');
  } else {
    b.write(
      '你是辩手「$speaker」，现在是第 $round / $rounds 轮。'
      '请针对其他辩手的观点进行反驳，指出其中的错误或漏洞，同时补充和完善你自己的论点。'
      '不要重复已经说过的内容。',
    );
  }
  return b.toString();
}
