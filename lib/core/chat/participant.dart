import 'dart:convert';

/// 会话参与者：一个逻辑模型，可选绑定一个助手（提供系统提示词和参数）。
class Participant {
  const Participant({required this.modelId, this.agentId});

  final String modelId;
  final String? agentId;

  Map<String, dynamic> toJson() => {'modelId': modelId, 'agentId': ?agentId};

  factory Participant.fromJson(Map<String, dynamic> j) => Participant(
    modelId: j['modelId'] as String,
    agentId: j['agentId'] as String?,
  );

  static List<Participant> decodeList(String json) {
    try {
      return [
        for (final p in jsonDecode(json) as List)
          if (p is Map<String, dynamic> && p['modelId'] is String)
            Participant.fromJson(p),
      ];
    } catch (_) {
      return const [];
    }
  }

  static String encodeList(List<Participant> list) =>
      jsonEncode([for (final p in list) p.toJson()]);

  @override
  bool operator ==(Object other) =>
      other is Participant &&
      other.modelId == modelId &&
      other.agentId == agentId;

  @override
  int get hashCode => Object.hash(modelId, agentId);
}
