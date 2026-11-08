import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../core/api/adapters/adapter.dart';
import '../core/api/api_error.dart';
import '../core/api/chat_client.dart';
import '../core/api/endpoint.dart';
import '../core/api/protocol.dart';
import '../core/chat/chat_types.dart';
import '../core/chat/conversation_mode.dart';
import '../core/chat/participant.dart';
import '../core/models/capabilities.dart';
import '../core/routing/model_router.dart';
import 'db/app_database.dart';
import 'ids.dart';
import 'image_store.dart';
import 'repositories/channel_repository.dart';

/// 待发送的图片（已压缩）。
class PendingImage {
  const PendingImage(this.bytes, this.mime);
  final Uint8List bytes;
  final String mime;
}

/// 消息状态。
abstract final class MsgStatus {
  static const pending = 'pending';
  static const streaming = 'streaming';
  static const done = 'done';
  static const error = 'error';
  static const stopped = 'stopped';

  static bool isActive(String s) => s == pending || s == streaming;
}

/// 聊天引擎：发送、流式生成、停止、重新生成、编辑重发、多 Agent 采纳。
class ChatService {
  ChatService({
    required this._db,
    required this._channels,
    required this._client,
    required this._router,
    required this._images,
  });

  final AppDatabase _db;
  final ChannelRepository _channels;
  final ChatClient _client;
  final ModelRouter _router;
  final ImageStore _images;

  final _cancels = <String, CancelToken>{};

  /// 不支持通过 Responses 接口联网的中转站（渠道 id|地址），本次运行内不再尝试。
  final _noResponsesSearch = <String>{};

  static const noSearchNotice = '该渠道不支持联网搜索，已按普通对话回答';

  /// 表示「接口或参数不被支持」的状态码。
  static const _unsupported = {400, 404, 405, 415, 422, 501};

  /// 写库节流间隔：流式输出时不必每个 token 都写一次数据库。
  static const flushInterval = Duration(milliseconds: 80);

  // ──────────────── 会话

  Future<Conversation?> conversation(String id) => (_db.select(
    _db.conversations,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  static const defaultTitle = '新对话';

  Future<String> createConversation(
    List<Participant> participants, {
    ConversationMode? mode,
    String title = defaultTitle,
  }) async {
    final id = newId();
    final now = DateTime.now();
    await _db
        .into(_db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: id,
            title: title,
            mode: Value(_modeFor(participants, mode).id),
            participantsJson: Value(Participant.encodeList(participants)),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> setParticipants(
    String convId,
    List<Participant> participants, {
    ConversationMode? mode,
  }) =>
      (_db.update(_db.conversations)..where((c) => c.id.equals(convId))).write(
        ConversationsCompanion(
          participantsJson: Value(Participant.encodeList(participants)),
          mode: Value(_modeFor(participants, mode).id),
        ),
      );

  /// 单个参与者总是单模型模式；多个参与者默认并问。
  static ConversationMode _modeFor(
    List<Participant> participants,
    ConversationMode? mode,
  ) {
    if (participants.length <= 1) return ConversationMode.single;
    return mode == null || mode == ConversationMode.single
        ? ConversationMode.multi
        : mode;
  }

  Future<void> setWebSearch(String convId, bool on) =>
      (_db.update(_db.conversations)..where((c) => c.id.equals(convId))).write(
        ConversationsCompanion(webSearch: Value(on)),
      );

  Future<void> rename(String convId, String title) =>
      (_db.update(_db.conversations)..where((c) => c.id.equals(convId))).write(
        ConversationsCompanion(
          title: Value(title.trim().isEmpty ? defaultTitle : title.trim()),
        ),
      );

  Future<void> setPinned(String convId, bool pinned) =>
      (_db.update(_db.conversations)..where((c) => c.id.equals(convId))).write(
        ConversationsCompanion(pinned: Value(pinned)),
      );

  Future<void> deleteConversation(String convId) async {
    final msgs = await (_db.select(
      _db.messages,
    )..where((m) => m.conversationId.equals(convId))).get();
    for (final m in msgs) {
      _cancels.remove(m.id)?.cancel();
    }
    await _db.deleteConversation(convId);
    await _deleteImagesOf(msgs);
  }

  /// 新建后什么都没做（没选模型、没发消息、没改名或置顶）就离开的会话直接丢弃，
  /// 不在列表里留下一堆空的「新对话」。返回是否删除了。
  ///
  /// [force]：「新对话追问」打开的对话，只要没发过消息就丢弃（它自带模型和标题）。
  Future<bool> discardIfEmpty(String convId, {bool force = false}) async {
    final c = await conversation(convId);
    if (c == null) return false;
    if (!force &&
        (c.pinned ||
            c.title != defaultTitle ||
            Participant.decodeList(c.participantsJson).isNotEmpty)) {
      return false;
    }
    final any =
        await (_db.select(_db.messages)
              ..where((m) => m.conversationId.equals(convId))
              ..limit(1))
            .getSingleOrNull();
    if (any != null) return false;
    await _db.deleteConversation(convId);
    return true;
  }

  // ──────────────── 追问

  /// 「新对话追问」对话的标题前缀（启动清理也按它识别没发过消息的追问对话）。
  static const followUpPrefix = '追问：';

  static String followUpTitle(String selection) {
    final t = selection.trim().replaceAll(RegExp(r'\s+'), ' ');
    return '$followUpPrefix${t.length > 20 ? '${t.substring(0, 20)}…' : t}';
  }

  /// 「新对话追问」：用回答 [sourceMsgId] 的 Agent 新建单模型对话，标题为「追问：xxx」。
  Future<String> createFollowUp(String sourceMsgId, String selection) async {
    final src = await _message(sourceMsgId);
    if (src == null || src.modelId == null) throw ApiException('原回答不存在');
    return createConversation([
      Participant(modelId: src.modelId!, agentId: src.agentId),
    ], title: followUpTitle(selection));
  }

  /// 用回答 [sourceMsgId] 的 Agent，把它之前的对话（含这条回答）总结成新对话的背景。
  /// 逐步产出当前已生成的完整文字；渠道失败时在开始输出前自动换下一个渠道。
  Stream<String> summarize(
    String sourceMsgId, {
    required String selection,
    CancelToken? cancel,
  }) async* {
    final src = await _message(sourceMsgId);
    if (src == null) throw ApiException('原回答不存在');
    final (:model, :agent, :candidates) = await _resolve(src);

    final history = [
      ...await _history(src),
      ChatTurn(
        role: 'assistant',
        text: ContentPart.decodeList(src.partsJson).text,
      ),
      ChatTurn(
        role: 'user',
        text:
            '我接下来要在一个新对话里，针对你回答中的这段内容继续追问：\n'
            '「${selection.trim()}」\n\n'
            '请把以上对话总结成新对话的背景：说明我最初的问题、讨论中的关键信息、'
            '你给出的主要结论，侧重与这段内容相关的部分。直接输出总结，'
            '不要寒暄，不要回答追问本身，控制在 300 字以内。',
      ),
    ];

    for (final (i, route) in candidates.indexed) {
      final endpoint = await _channels.endpointFor(route.channel);
      final req = ChatRequest(
        model: route.route.upstreamModel,
        turns: history,
        system: agent?.systemPrompt,
        params: agent == null
            ? const GenParams()
            : GenParams.fromJson(agent.paramsJson),
        reasoningCapable: false,
        presetId: route.channel.presetId,
        webSearch: false,
      );
      final out = StringBuffer();
      try {
        await for (final ev in _client.stream(endpoint, req, cancel: cancel)) {
          if (ev case TextDelta(:final text)) {
            out.write(text);
            yield out.toString();
          }
        }
        if (out.isEmpty) throw ApiException('模型没有返回任何内容');
        _router.reportSuccess(route.channel.id);
        return;
      } on ApiException catch (e) {
        if (cancel?.isCancelled ?? false) return;
        _router.reportFailure(route.channel.id);
        if (out.isNotEmpty || !_retryable(e) || i == candidates.length - 1) {
          rethrow;
        }
      }
    }
  }

  // ──────────────── 发送

  /// 发送用户消息。[quote] 为追问时引用的回答片段，[context] 为新对话追问时的
  /// 前文总结；两者都只拼进发给模型的文字，界面上单独展示。
  Future<void> send(
    String convId,
    String text, {
    List<PendingImage> images = const [],
    String? quote,
    String? context,
  }) async {
    final conv = await conversation(convId);
    if (conv == null) return;
    final participants = Participant.decodeList(conv.participantsJson);
    if (participants.isEmpty) throw ApiException('请先选择模型');

    final parts = <ContentPart>[
      if (context case final c? when c.trim().isNotEmpty) ContextPart(c.trim()),
      if (quote case final q? when q.trim().isNotEmpty) QuotePart(q.trim()),
      for (final img in images) await _images.save(img.bytes, img.mime),
      if (text.trim().isNotEmpty) TextPart(text.trim()),
    ];
    final now = DateTime.now();
    await _db.addMessage(
      MessagesCompanion.insert(
        id: newId(),
        conversationId: convId,
        role: 'user',
        partsJson: Value(ContentPart.encodeList(parts)),
        createdAt: now,
      ),
    );

    if (conv.title == defaultTitle) {
      final t = (text.trim().isEmpty ? (quote ?? '') : text.trim()).replaceAll(
        RegExp(r'\s+'),
        ' ',
      );
      await rename(
        convId,
        t.isEmpty ? '图片' : (t.length > 30 ? '${t.substring(0, 30)}…' : t),
      );
    }

    await _startAnswers(conv, participants, after: now);
  }

  /// 为每个参与者创建一条助手消息并开始生成。多个参与者时共享 groupId。
  /// 接力模式下按顺序逐个生成，其余模式并发生成。
  Future<void> _startAnswers(
    Conversation conv,
    List<Participant> participants, {
    required DateTime after,
  }) async {
    final convId = conv.id;
    final groupId = newId();
    final mode = ConversationMode.fromId(
      conv.mode,
      participants: participants.length,
    );
    final chain = mode == ConversationMode.chain && participants.length > 1;
    final multi = participants.length > 1;
    for (final (i, p) in participants.indexed) {
      final id = newId();
      await _db.addMessage(
        MessagesCompanion.insert(
          id: id,
          conversationId: convId,
          role: 'assistant',
          groupId: Value(groupId),
          adopted: Value(!multi),
          modelId: Value(p.modelId),
          agentId: Value(p.agentId),
          stepIndex: Value(chain ? i : null),
          status: const Value(MsgStatus.pending),
          // 同组消息按参与者顺序排列。
          createdAt: after.add(Duration(microseconds: i + 1)),
        ),
      );
      if (!chain) unawaited(_generate(id));
    }
    if (chain) unawaited(_runChain(groupId, from: 0));
  }

  // ──────────────── 接力分析

  Future<List<Message>> _chainSteps(String groupId) async {
    final steps = await (_db.select(
      _db.messages,
    )..where((m) => m.groupId.equals(groupId))).get();
    return steps.where((m) => m.stepIndex != null).toList()
      ..sort((a, b) => a.stepIndex!.compareTo(b.stepIndex!));
  }

  /// 从第 [from] 步开始依次生成。某一步没有成功完成时中止后续步骤。
  /// 结束后采纳最后一个成功的步骤，作为本轮结论进入后续对话的上下文。
  Future<void> _runChain(String groupId, {required int from}) async {
    for (final step in await _chainSteps(groupId)) {
      if (step.stepIndex! < from) continue;
      // 重新读取：上一步运行期间该步骤可能已被删除或停止。
      final current = await _message(step.id);
      if (current == null) continue;
      if (current.status == MsgStatus.stopped) {
        await _abortChainAfter(groupId, step.stepIndex!, '接力已停止');
        break;
      }
      await _generate(step.id);
      final done = await _message(step.id);
      if (done == null) continue;
      if (done.status != MsgStatus.done) {
        await _abortChainAfter(
          groupId,
          step.stepIndex!,
          done.status == MsgStatus.stopped ? '接力已停止' : '上一步失败，接力已中止',
        );
        break;
      }
    }
    await _adoptChainResult(groupId);
  }

  Future<void> _abortChainAfter(String groupId, int step, String reason) async {
    for (final s in await _chainSteps(groupId)) {
      if (s.stepIndex! > step && MsgStatus.isActive(s.status)) {
        await _update(
          s.id,
          MessagesCompanion(
            status: const Value(MsgStatus.stopped),
            error: Value(reason),
          ),
        );
      }
    }
  }

  Future<void> _adoptChainResult(String groupId) async {
    final last = (await _chainSteps(groupId))
        .where((s) => s.status == MsgStatus.done)
        .lastOrNull;
    if (last != null) await adopt(last.id);
  }

  /// 参与者显示名：助手名，否则模型显示名。
  Future<String> _labelOf(Message m) async {
    if (m.agentId case final id?) {
      final agent = await (_db.select(
        _db.agents,
      )..where((a) => a.id.equals(id))).getSingleOrNull();
      if (agent != null) return agent.name;
    }
    final model = await (_db.select(
      _db.models,
    )..where((x) => x.id.equals(m.modelId ?? ''))).getSingleOrNull();
    return model?.displayName ?? m.upstreamModel ?? '上一个模型';
  }

  /// 接力步骤：把上下文最后一条用户消息换成「原始问题 + 上一步结果」。
  Future<List<ChatTurn>> _chainHistory(
    Message msg,
    List<ChatTurn> history,
  ) async {
    final step = msg.stepIndex;
    if (step == null || step == 0 || msg.groupId == null) return history;
    final prev = (await _chainSteps(msg.groupId!))
        .where((s) => s.stepIndex == step - 1)
        .firstOrNull;
    if (prev == null) return history;
    final idx = history.lastIndexWhere((t) => t.role == 'user');
    if (idx < 0) return history;
    final original = history[idx];
    final composed = buildChainPrompt(
      question: original.text,
      step: step,
      previousLabel: await _labelOf(prev),
      previousOutput: ContentPart.decodeList(prev.partsJson).text,
    );
    return [
      ...history.sublist(0, idx),
      ChatTurn(role: 'user', text: composed, images: original.images),
      ...history.sublist(idx + 1),
    ];
  }

  // ──────────────── 生成

  Future<Message?> _message(String id) => (_db.select(
    _db.messages,
  )..where((m) => m.id.equals(id))).getSingleOrNull();

  Future<void> _update(String id, MessagesCompanion data) =>
      (_db.update(_db.messages)..where((m) => m.id.equals(id))).write(data);

  /// 一条助手消息对应的模型、助手和按路由策略排好序的候选渠道。
  Future<({ModelWithRoutes model, Agent? agent, List<RouteInfo> candidates})>
  _resolve(Message msg) async {
    final models = await _channels.watchModels().first;
    final model = models.where((m) => m.model.id == msg.modelId).firstOrNull;
    if (model == null) throw ApiException('模型不存在或已被删除，请重新选择');
    final agent = msg.agentId == null
        ? null
        : await (_db.select(
            _db.agents,
          )..where((a) => a.id.equals(msg.agentId!))).getSingleOrNull();
    final candidates = _router.order(model);
    if (candidates.isEmpty) {
      throw ApiException('「${model.model.displayName}」没有可用渠道（渠道可能已停用）');
    }
    return (model: model, agent: agent, candidates: candidates);
  }

  Future<void> _generate(String msgId) async {
    final msg = await _message(msgId);
    // 已被停止（接力中排队的步骤）则不再生成。
    if (msg == null || msg.status == MsgStatus.stopped) return;
    final conv = await conversation(msg.conversationId);
    if (conv == null) return;

    final cancel = CancelToken();
    _cancels[msgId] = cancel;
    try {
      final (:model, :agent, :candidates) = await _resolve(msg);

      final history = await _chainHistory(msg, await _history(msg));
      await _runWithFailover(
        msg: msg,
        model: model,
        candidates: candidates,
        history: history,
        system: agent?.systemPrompt,
        params: agent == null
            ? const GenParams()
            : GenParams.fromJson(agent.paramsJson),
        webSearch: conv.webSearch,
        cancel: cancel,
      );
      if (msg.stepIndex == null) await _adoptIfFirst(msgId);
    } on ApiException catch (e) {
      if (cancel.isCancelled) {
        await _update(
          msgId,
          const MessagesCompanion(status: Value(MsgStatus.stopped)),
        );
      } else {
        await _update(
          msgId,
          MessagesCompanion(
            status: const Value(MsgStatus.error),
            error: Value(e.toString()),
          ),
        );
      }
    } catch (e) {
      await _update(
        msgId,
        MessagesCompanion(
          status: const Value(MsgStatus.error),
          error: Value('$e'),
        ),
      );
    } finally {
      _cancels.remove(msgId);
    }
  }

  static bool _retryable(ApiException e) {
    final s = e.statusCode;
    // 无状态码 = 网络 / 超时；401/403 = 该渠道 Key 问题；429/5xx = 限流或服务端故障。
    return s == null ||
        s == 401 ||
        s == 403 ||
        s == 404 ||
        s == 429 ||
        s >= 500;
  }

  Future<void> _runWithFailover({
    required Message msg,
    required ModelWithRoutes model,
    required List<RouteInfo> candidates,
    required List<ChatTurn> history,
    required String? system,
    required GenParams params,
    required bool webSearch,
    required CancelToken cancel,
  }) async {
    final failures = <String>[];
    for (final (i, route) in candidates.indexed) {
      final endpoint = await _channels.endpointFor(route.channel);
      final upstream = route.route.upstreamModel;
      await _update(
        msg.id,
        MessagesCompanion(
          status: const Value(MsgStatus.pending),
          channelId: Value(route.channel.id),
          upstreamModel: Value(upstream),
          error: const Value(null),
        ),
      );

      var acc = _Accumulator(_images);
      try {
        if (inferModelProfile(upstream).kind == ModelKind.image) {
          await _generateImage(msg, endpoint, upstream, history, acc, cancel);
        } else {
          final search =
              webSearch &&
              supportsWebSearch(
                protocol: endpoint.protocol,
                presetId: route.channel.presetId,
                model: upstream,
                baseUrl: endpoint.baseUrl,
              );
          final target = search
              ? endpoint.forWebSearch(
                  presetId: route.channel.presetId,
                  model: upstream,
                )
              : endpoint;
          ChatRequest request({required bool webSearch}) => ChatRequest(
            model: upstream,
            turns: history,
            system: system,
            params: params,
            reasoningCapable: model.capabilities.contains(
              ModelCapability.reasoning,
            ),
            presetId: route.channel.presetId,
            webSearch: webSearch,
          );
          // 中转站开联网：改走同地址的 Responses 接口。已知不支持的渠道直接按普通对话。
          final viaResponses =
              target.protocol == ApiProtocol.openaiResponses &&
              endpoint.protocol == ApiProtocol.openaiChat;
          final key = '${route.channel.id}|${endpoint.baseUrl}';
          if (viaResponses && _noResponsesSearch.contains(key)) {
            acc.extra.add(const NoticePart(noSearchNotice));
            await _stream(
              msg.id,
              endpoint,
              request(webSearch: false),
              acc,
              cancel,
            );
          } else {
            try {
              await _stream(
                msg.id,
                target,
                request(webSearch: search),
                acc,
                cancel,
              );
            } on ApiException catch (e) {
              // 只有「接口 / 参数不被支持」类错误（400/404/405/415/422/501）才说明
              // 中转站不支持 Responses 接口或其中的搜索工具：退回原接口按普通对话
              // 回答并记住。超时、网络、5xx 等临时故障照常走渠道切换，
              // 不能因为一次抖动就关掉这个渠道的联网。
              if (!viaResponses ||
                  cancel.isCancelled ||
                  acc.started ||
                  !_unsupported.contains(e.statusCode)) {
                rethrow;
              }
              _noResponsesSearch.add(key);
              acc = _Accumulator(_images)
                ..extra.add(const NoticePart(noSearchNotice));
              await _stream(
                msg.id,
                endpoint,
                request(webSearch: false),
                acc,
                cancel,
              );
            }
          }
        }
        _router.reportSuccess(route.channel.id);
        await _update(
          msg.id,
          MessagesCompanion(
            partsJson: Value(ContentPart.encodeList(acc.parts)),
            status: const Value(MsgStatus.done),
            usageJson: Value(acc.usageJson),
          ),
        );
        return;
      } on ApiException catch (e) {
        if (cancel.isCancelled) {
          await _update(
            msg.id,
            MessagesCompanion(
              partsJson: Value(ContentPart.encodeList(acc.parts)),
              status: const Value(MsgStatus.stopped),
            ),
          );
          return;
        }
        _router.reportFailure(route.channel.id);
        final isLast = i == candidates.length - 1;
        // 已经输出了内容就不再切换渠道（避免内容重复）。
        if (acc.started || !_retryable(e) || isLast) {
          final prefix = failures.isEmpty
              ? ''
              : '已尝试 ${failures.length + 1} 个渠道。\n';
          await _update(
            msg.id,
            MessagesCompanion(
              partsJson: Value(ContentPart.encodeList(acc.parts)),
              status: const Value(MsgStatus.error),
              error: Value('$prefix「${route.channel.name}」$e'),
            ),
          );
          return;
        }
        failures.add(route.channel.name);
      }
    }
  }

  Future<void> _stream(
    String msgId,
    ChannelEndpoint endpoint,
    ChatRequest req,
    _Accumulator acc,
    CancelToken cancel,
  ) async {
    Timer? timer;
    var dirty = false;
    Future<void> flush() async {
      if (!dirty) return;
      dirty = false;
      await _update(
        msgId,
        MessagesCompanion(
          partsJson: Value(ContentPart.encodeList(acc.parts)),
          status: const Value(MsgStatus.streaming),
        ),
      );
    }

    try {
      await for (final ev in _client.stream(endpoint, req, cancel: cancel)) {
        await acc.add(ev);
        dirty = true;
        timer ??= Timer(flushInterval, () {
          timer = null;
          flush();
        });
      }
    } finally {
      timer?.cancel();
    }
    if (!acc.started) throw ApiException('模型没有返回任何内容');
  }

  Future<void> _generateImage(
    Message msg,
    ChannelEndpoint endpoint,
    String upstream,
    List<ChatTurn> history,
    _Accumulator acc,
    CancelToken cancel,
  ) async {
    final last = history.lastWhere(
      (t) => t.role == 'user',
      orElse: () => const ChatTurn(role: 'user', text: ''),
    );
    if (last.text.trim().isEmpty) throw ApiException('请输入图片描述');
    await _update(
      msg.id,
      const MessagesCompanion(status: Value(MsgStatus.streaming)),
    );
    final result = await _client.generateImage(
      endpoint,
      model: upstream,
      prompt: last.text,
      references: last.images,
      cancel: cancel,
    );
    for (final r in result) {
      acc.extra.add(await _images.save(r.bytes, r.mime));
      if (r.revisedPrompt case final p? when p.isNotEmpty) {
        acc.extra.add(TextPart(p));
      }
    }
    acc.started = true;
  }

  /// 构造上下文：本条消息之前的用户消息 + 已采纳的、完成的助手回答（排除同组其他回答）。
  Future<List<ChatTurn>> _history(Message target) async {
    final ordered = await _db.messagesOf(target.conversationId);
    final idx = ordered.indexWhere((m) => m.id == target.id);
    final all = idx < 0 ? ordered : ordered.sublist(0, idx);
    final turns = <ChatTurn>[];
    for (final m in all) {
      final parts = ContentPart.decodeList(m.partsJson);
      if (m.role == 'user') {
        final imgs = <InlineImage>[
          for (final p in parts.images) ?await _images.readInline(p),
        ];
        turns.add(ChatTurn(role: 'user', text: parts.promptText, images: imgs));
      } else if (m.role == 'assistant' &&
          m.adopted &&
          m.groupId != target.groupId &&
          (m.status == MsgStatus.done || m.status == MsgStatus.stopped) &&
          parts.text.isNotEmpty) {
        turns.add(ChatTurn(role: 'assistant', text: parts.text));
      }
    }
    return turns;
  }

  /// 多 Agent：组内第一个完成的回答自动被采纳。
  Future<void> _adoptIfFirst(String msgId) async {
    final msg = await _message(msgId);
    if (msg == null || msg.groupId == null || msg.status != MsgStatus.done) {
      return;
    }
    await _db.transaction(() async {
      final siblings = await (_db.select(
        _db.messages,
      )..where((m) => m.groupId.equals(msg.groupId!))).get();
      if (siblings.length <= 1 || siblings.any((s) => s.adopted)) return;
      await _update(msgId, const MessagesCompanion(adopted: Value(true)));
    });
  }

  // ──────────────── 操作

  bool isGenerating(String msgId) => _cancels.containsKey(msgId);

  void stop(String msgId) => _cancels[msgId]?.cancel('stopped');

  Future<void> stopConversation(String convId) async {
    final msgs = await (_db.select(
      _db.messages,
    )..where((m) => m.conversationId.equals(convId))).get();
    for (final m in msgs) {
      if (_cancels.containsKey(m.id)) {
        stop(m.id);
      } else if (m.status == MsgStatus.pending) {
        // 接力中还没轮到的步骤。
        await _update(
          m.id,
          const MessagesCompanion(
            status: Value(MsgStatus.stopped),
            error: Value('接力已停止'),
          ),
        );
      }
    }
  }

  Future<void> regenerate(String msgId) async {
    final msg = await _message(msgId);
    if (msg == null || msg.role != 'assistant') return;
    if (msg.stepIndex != null && msg.groupId != null) {
      return _regenerateChainFrom(msg.groupId!, msg.stepIndex!);
    }
    stop(msgId);
    await _deleteImagesOf([msg]);
    await _update(
      msgId,
      const MessagesCompanion(
        partsJson: Value('[]'),
        status: Value(MsgStatus.pending),
        error: Value(null),
        usageJson: Value(null),
      ),
    );
    unawaited(_generate(msgId));
  }

  /// 接力：从第 [step] 步起全部重新生成（后面的步骤依赖前面的结果）。
  Future<void> _regenerateChainFrom(String groupId, int step) async {
    final steps = (await _chainSteps(groupId))
        .where((s) => s.stepIndex! >= step)
        .toList();
    for (final s in steps) {
      stop(s.id);
    }
    await _deleteImagesOf(steps);
    for (final s in steps) {
      await _update(
        s.id,
        const MessagesCompanion(
          partsJson: Value('[]'),
          status: Value(MsgStatus.pending),
          error: Value(null),
          usageJson: Value(null),
          adopted: Value(false),
        ),
      );
    }
    unawaited(_runChain(groupId, from: step));
  }

  Future<void> adopt(String msgId) async {
    final msg = await _message(msgId);
    if (msg == null || msg.groupId == null) return;
    await _db.transaction(() async {
      await (_db.update(_db.messages)
            ..where((m) => m.groupId.equals(msg.groupId!)))
          .write(const MessagesCompanion(adopted: Value(false)));
      await _update(msgId, const MessagesCompanion(adopted: Value(true)));
    });
  }

  Future<void> deleteMessage(String msgId) async {
    final msg = await _message(msgId);
    if (msg == null) return;
    stop(msgId);
    await (_db.delete(_db.messages)..where((m) => m.id.equals(msgId))).go();
    await _deleteImagesOf([msg]);
  }

  /// 修改用户消息并重新回答：删除其后所有消息，按当前参与者重新生成。
  Future<void> editAndResend(String userMsgId, String newText) async {
    final msg = await _message(userMsgId);
    if (msg == null || msg.role != 'user') return;
    final conv = await conversation(msg.conversationId);
    if (conv == null) return;

    final ordered = await _db.messagesOf(msg.conversationId);
    final after = ordered.sublist(
      ordered.indexWhere((m) => m.id == msg.id) + 1,
    );
    for (final m in after) {
      stop(m.id);
    }
    await (_db.delete(
      _db.messages,
    )..where((m) => m.id.isIn([for (final m in after) m.id]))).go();
    await _deleteImagesOf(after);

    final parts = ContentPart.decodeList(msg.partsJson);
    final newParts = [
      ...parts.whereType<ContextPart>(),
      ...parts.whereType<QuotePart>(),
      ...parts.images,
      if (newText.trim().isNotEmpty) TextPart(newText.trim()),
    ];
    await _update(
      userMsgId,
      MessagesCompanion(partsJson: Value(ContentPart.encodeList(newParts))),
    );

    final participants = Participant.decodeList(conv.participantsJson);
    if (participants.isEmpty) throw ApiException('请先选择模型');
    await _startAnswers(conv, participants, after: msg.createdAt);
  }

  Future<void> _deleteImagesOf(List<Message> msgs) async {
    for (final m in msgs) {
      for (final img in ContentPart.decodeList(m.partsJson).images) {
        await _images.delete(img.path);
      }
    }
  }
}

/// 把流式事件累积成消息内容块。
class _Accumulator {
  _Accumulator(this._images);

  final ImageStore _images;
  final _thinking = StringBuffer();
  final _text = StringBuffer();
  final _citations = <String, CitationPart>{};
  final _imageParts = <ImagePart>[];
  int? _in;
  int? _out;
  bool started = false;

  /// 非流式路径（生图）直接往这里加。
  final extra = <ContentPart>[];

  List<ContentPart> get parts => [
    if (_thinking.isNotEmpty) ThinkingPart(_thinking.toString()),
    ..._imageParts,
    ...extra,
    if (_text.isNotEmpty) TextPart(_text.toString()),
    ..._citations.values,
  ];

  String? get usageJson => _in == null && _out == null
      ? null
      : jsonEncode({'input': ?_in, 'output': ?_out});

  Future<void> add(ChatEvent e) async {
    switch (e) {
      case TextDelta(:final text):
        _text.write(text);
        started = true;
      case ThinkingDelta(:final text):
        _thinking.write(text);
        started = true;
      case CitationEvent(:final url, :final title):
        _citations.putIfAbsent(url, () => CitationPart(url, title));
      case ImageEvent(:final base64, :final mime):
        _imageParts.add(await _images.save(base64Decode(base64), mime));
        started = true;
      case UsageEvent(:final input, :final output):
        _in = input ?? _in;
        _out = output ?? _out;
    }
  }
}
