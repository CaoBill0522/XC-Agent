/// 渠道使用的接口协议。[id] 是存进数据库的值，不要改。
enum ApiProtocol {
  openaiChat('openai_chat', 'OpenAI Chat Completions'),
  openaiResponses('openai_responses', 'OpenAI Responses'),
  anthropic('anthropic', 'Anthropic Messages');

  const ApiProtocol(this.id, this.label);

  final String id;
  final String label;

  bool get isOpenAI => this != anthropic;

  static ApiProtocol fromId(String id) =>
      values.firstWhere((p) => p.id == id, orElse: () => openaiChat);
}
