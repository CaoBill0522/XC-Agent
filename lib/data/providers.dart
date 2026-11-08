import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api/channel_client.dart';
import '../core/api/chat_client.dart';
import '../core/chat/conversation_mode.dart';
import '../core/chat/participant.dart';
import '../core/providers/provider_preset.dart';
import '../core/routing/model_router.dart';
import 'chat_service.dart';
import 'db/app_database.dart';
import 'image_store.dart';
import 'repositories/agent_repository.dart';
import 'repositories/channel_repository.dart';
import 'secure/key_store.dart';

export 'ids.dart';

// ──────────────── 基础服务

/// 在 main() 里用 `await SharedPreferences.getInstance()` 覆盖。
final prefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(),
);

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final keyStoreProvider = Provider<KeyStore>((ref) => SecureKeyStore());
final imageStoreProvider = Provider<ImageStore>((ref) => ImageStore());
final modelRouterProvider = Provider<ModelRouter>((ref) => ModelRouter());
final channelClientProvider = Provider<ChannelClient>((ref) => ChannelClient());
final chatClientProvider = Provider<ChatClient>((ref) => ChatClient());

final channelRepositoryProvider = Provider<ChannelRepository>((ref) {
  return ChannelRepository(
    ref.watch(databaseProvider),
    ref.watch(keyStoreProvider),
  );
});

final agentRepositoryProvider = Provider<AgentRepository>((ref) {
  return AgentRepository(ref.watch(databaseProvider));
});

final chatServiceProvider = Provider<ChatService>((ref) {
  return ChatService(
    db: ref.watch(databaseProvider),
    channels: ref.watch(channelRepositoryProvider),
    client: ref.watch(chatClientProvider),
    router: ref.watch(modelRouterProvider),
    images: ref.watch(imageStoreProvider),
  );
});

// ──────────────── 数据流

final presetsProvider = FutureProvider<List<ProviderPreset>>(
  (ref) => ProviderPreset.load(),
);

final channelsProvider = StreamProvider<List<ChannelSummary>>((ref) {
  return ref.watch(channelRepositoryProvider).watchChannels();
});

final modelsProvider = StreamProvider<List<ModelWithRoutes>>((ref) {
  return ref.watch(channelRepositoryProvider).watchModels();
});

final agentsProvider = StreamProvider<List<Agent>>((ref) {
  return ref.watch(agentRepositoryProvider).watchAll();
});

final conversationsProvider = StreamProvider<List<Conversation>>((ref) {
  return ref.watch(databaseProvider).watchConversations();
});

final conversationProvider = Provider.family<Conversation?, String>((ref, id) {
  return ref
      .watch(conversationsProvider)
      .value
      ?.where((c) => c.id == id)
      .firstOrNull;
});

final messagesProvider = StreamProvider.family<List<Message>, String>((
  ref,
  conversationId,
) {
  return ref.watch(databaseProvider).watchMessages(conversationId);
});

/// 当前选中的会话（桌面双栏右侧显示的会话）。
class SelectedConversation extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedConversationProvider =
    NotifierProvider<SelectedConversation, String?>(SelectedConversation.new);

// ──────────────── 参与者显示

/// 参与者的显示名：有助手用助手名，否则用模型名。
String participantLabel(
  Participant p,
  List<ModelWithRoutes> models,
  List<Agent> agents,
) {
  final agent = p.agentId == null
      ? null
      : agents.where((a) => a.id == p.agentId).firstOrNull;
  final model = models.where((m) => m.model.id == p.modelId).firstOrNull;
  if (agent != null) return agent.name;
  return model?.model.displayName ?? '未知模型';
}

// ──────────────── 新建会话

const _lastParticipantsKey = 'last_participants';
const _lastModeKey = 'last_mode';

void rememberParticipants(
  WidgetRef ref,
  List<Participant> list,
  ConversationMode mode,
) {
  final prefs = ref.read(prefsProvider);
  prefs.setString(_lastParticipantsKey, Participant.encodeList(list));
  prefs.setString(_lastModeKey, mode.id);
}

/// 上次使用的设置（参与者都仍然可用时），作为新会话「沿用上次」的快捷选项。
/// 新会话本身不再自动套用，由用户在空白聊天页里选择。
({List<Participant> participants, ConversationMode mode})? lastSetup(
  WidgetRef ref,
  List<ModelWithRoutes> models,
  List<Agent> agents,
) {
  final usable = {
    for (final m in models)
      if (m.model.enabled && m.routes.isNotEmpty) m.model.id,
  };
  final prefs = ref.read(prefsProvider);
  final saved = Participant.decodeList(
    prefs.getString(_lastParticipantsKey) ?? '[]',
  );
  final valid = saved.every(
    (p) =>
        usable.contains(p.modelId) &&
        (p.agentId == null || agents.any((a) => a.id == p.agentId)),
  );
  if (saved.isEmpty || !valid) return null;
  final mode = saved.length > 1
      ? ConversationMode.fromId(
          prefs.getString(_lastModeKey),
          participants: saved.length,
        )
      : ConversationMode.single;
  return (participants: saved, mode: mode);
}

/// 新建空会话：模式和模型在聊天页里选。
Future<String> createConversation(WidgetRef ref) =>
    ref.read(chatServiceProvider).createConversation(const []);

// ──────────────── JSON 工具

String prettyJson(Object? o) => const JsonEncoder.withIndent('  ').convert(o);
