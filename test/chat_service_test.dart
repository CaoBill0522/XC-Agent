import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent/core/api/api_error.dart';
import 'package:agent/core/api/chat_client.dart';
import 'package:agent/core/api/protocol.dart';
import 'package:agent/core/chat/chat_types.dart';
import 'package:agent/core/chat/conversation_mode.dart';
import 'package:agent/core/chat/conversation_options.dart';
import 'package:agent/core/chat/participant.dart';
import 'package:agent/core/routing/model_router.dart';
import 'package:agent/data/chat_service.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/image_store.dart';
import 'package:agent/data/repositories/channel_repository.dart';
import 'package:agent/data/secure/key_store.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Handler = FutureOr<ResponseBody> Function(RequestOptions o);

class ScriptedAdapter implements HttpClientAdapter {
  ScriptedAdapter(this.handler);
  Handler handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? _,
    Future<void>? cancelFuture,
  ) async {
    requests.add(o);
    return handler(o);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody sse(
  List<String> dataLines, {
  int status = 200,
  Duration delay = Duration.zero,
}) {
  final controller = StreamController<Uint8List>();
  () async {
    for (final l in dataLines) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (controller.isClosed) return;
      controller.add(Uint8List.fromList(utf8.encode('data: $l\n\n')));
    }
    await controller.close();
  }();
  return ResponseBody(
    controller.stream,
    status,
    headers: {
      'content-type': ['text/event-stream'],
    },
  );
}

ResponseBody json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    'content-type': ['application/json'],
  },
);

String chunk(String text) => jsonEncode({
  'choices': [
    {
      'delta': {'content': text},
    },
  ],
});

void main() {
  late AppDatabase db;
  late ChannelRepository repo;
  late ScriptedAdapter http;
  late ChatService chat;
  late ModelRouter router;
  late Directory tmp;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = ChannelRepository(db, MemoryKeyStore());
    http = ScriptedAdapter((_) => sse([chunk('hi'), '[DONE]']));
    router = ModelRouter();
    tmp = await Directory.systemTemp.createTemp('agent_test');
    chat = ChatService(
      db: db,
      channels: repo,
      client: ChatClient(Dio()..httpClientAdapter = http),
      router: router,
      images: ImageStore(() async => tmp),
    );
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<String> channel(
    String host,
    List<String> models, {
    String strategy = 'failover',
  }) async {
    final id = await repo.saveChannel(
      name: host,
      presetId: 'custom',
      protocol: ApiProtocol.openaiChat,
      baseUrl: 'https://$host',
      apiKey: 'k',
    );
    await repo.syncChannelModels(id, models);
    return id;
  }

  Future<String> modelId(String name) async => (await repo.watchModels().first)
      .firstWhere((m) => m.model.displayName == name)
      .model
      .id;

  Future<List<Message>> settle(String convId) async {
    for (var i = 0; i < 200; i++) {
      final msgs = await db.watchMessages(convId).first;
      if (msgs.isNotEmpty && msgs.every((m) => !MsgStatus.isActive(m.status))) {
        return msgs;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('生成未结束');
  }

  String textOf(Message m) => ContentPart.decodeList(m.partsJson).text;

  test('发送：流式累积、完成状态、自动标题、记录渠道', () async {
    await channel('a.com', ['gpt-4o']);
    http.handler = (_) => sse([chunk('你'), chunk('好'), '[DONE]']);
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('gpt-4o')),
    ]);

    await chat.send(conv, '  打个招呼吧  ');
    final msgs = await settle(conv);

    expect(msgs.map((m) => m.role), ['user', 'assistant']);
    expect(textOf(msgs[1]), '你好');
    expect(msgs[1].status, MsgStatus.done);
    expect(msgs[1].upstreamModel, 'gpt-4o');
    expect((await chat.conversation(conv))!.title, '打个招呼吧');
    final body = http.requests.single.data as Map;
    expect((body['messages'] as List).last, {
      'role': 'user',
      'content': '打个招呼吧',
    });
  });

  test('故障切换：第一个渠道 500 时自动换下一个渠道', () async {
    await channel('bad.com', ['m']);
    await channel('good.com', ['m']);
    http.handler = (o) => o.uri.host == 'bad.com'
        ? json({
            'error': {'message': 'boom'},
          }, 500)
        : sse([chunk('ok'), '[DONE]']);
    // 显式设定优先级：bad.com 为主，good.com 为备。
    for (final r in (await repo.watchModels().first).single.routes) {
      await repo.updateRoute(
        r.route.id,
        priority: r.channel.name == 'bad.com' ? 0 : 1,
      );
    }
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('m')),
    ]);

    await chat.send(conv, 'q');
    final msgs = await settle(conv);
    expect(msgs.last.status, MsgStatus.done);
    expect(textOf(msgs.last), 'ok');
    expect(http.requests.map((r) => r.uri.host), ['bad.com', 'good.com']);
  });

  test('400 参数错误不切换渠道，直接报错', () async {
    await channel('a.com', ['m']);
    await channel('b.com', ['m']);
    http.handler = (_) => json({
      'error': {'message': 'bad param'},
    }, 400);
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('m')),
    ]);

    await chat.send(conv, 'q');
    final msgs = await settle(conv);
    expect(msgs.last.status, MsgStatus.error);
    expect(msgs.last.error, contains('bad param'));
    expect(http.requests, hasLength(1));
  });

  test('多 Agent：同组回答，先完成的被采纳；下一轮上下文只带被采纳的回答', () async {
    await channel('a.com', ['fast', 'slow']);
    http.handler = (o) {
      final model = (o.data as Map)['model'];
      return model == 'fast'
          ? sse([chunk('快的回答'), '[DONE]'])
          : sse([
              chunk('慢的回答'),
              '[DONE]',
            ], delay: const Duration(milliseconds: 30));
    };
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('slow')),
      Participant(modelId: await modelId('fast')),
    ]);

    await chat.send(conv, '第一问');
    var msgs = await settle(conv);
    final answers = msgs.where((m) => m.role == 'assistant').toList();
    expect(answers, hasLength(2));
    expect(answers.map((m) => m.groupId).toSet(), hasLength(1));
    expect(answers.firstWhere((m) => m.adopted).upstreamModel, 'fast');

    // 改为采纳慢的回答，再问一轮。
    await chat.adopt(answers.firstWhere((m) => m.upstreamModel == 'slow').id);
    http.requests.clear();
    http.handler = (_) => sse([chunk('ok'), '[DONE]']);
    await chat.send(conv, '第二问');
    await settle(conv);

    for (final r in http.requests) {
      final history = ((r.data as Map)['messages'] as List).cast<Map>();
      expect(history.map((m) => m['content']), ['第一问', '慢的回答', '第二问']);
    }
  });

  test('编辑重发：删除后续消息并重新生成', () async {
    await channel('a.com', ['m']);
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('m')),
    ]);
    await chat.send(conv, '旧问题');
    var msgs = await settle(conv);

    http.handler = (_) => sse([chunk('新回答'), '[DONE]']);
    await chat.editAndResend(msgs.first.id, '新问题');
    msgs = await settle(conv);
    expect(msgs.map(textOf), ['新问题', '新回答']);
  });

  test('停止：保留已输出内容，状态为 stopped', () async {
    await channel('a.com', ['m']);
    http.handler = (_) => sse([
      chunk('一'),
      chunk('二'),
      chunk('三'),
      '[DONE]',
    ], delay: const Duration(milliseconds: 60));
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('m')),
    ]);
    await chat.send(conv, 'q');

    // 等第一个字到达后停止。
    for (var i = 0; i < 100; i++) {
      final m = (await db.watchMessages(conv).first).last;
      if (textOf(m).isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await chat.stopConversation(conv);
    final msgs = await settle(conv);
    expect(msgs.last.status, MsgStatus.stopped);
    expect(textOf(msgs.last), isNot(contains('三')));
  });

  test('生图模型走 /images/generations，图片存到本地', () async {
    await channel('a.com', ['dall-e-3']);
    http.handler = (o) {
      expect(o.uri.path, '/v1/images/generations');
      expect((o.data as Map)['response_format'], 'b64_json');
      return json({
        'data': [
          {
            'b64_json': base64Encode([1, 2, 3]),
            'revised_prompt': '一只猫',
          },
        ],
      });
    };
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('dall-e-3')),
    ]);
    await chat.send(conv, '画只猫');
    final msgs = await settle(conv);
    final parts = ContentPart.decodeList(msgs.last.partsJson);
    expect(msgs.last.status, MsgStatus.done);
    expect(parts.images, hasLength(1));
    expect(parts.text, '一只猫');
    expect(
      await File('${tmp.path}/images/${parts.images.single.path}')
          .readAsBytes(),
      [1, 2, 3],
    );
  });

  test('路由：轮询策略依次使用各渠道；连续失败的渠道进入冷却', () async {
    await channel('a.com', ['m']);
    await channel('b.com', ['m']);
    final id = await modelId('m');
    await (db.update(db.models)..where((m) => m.id.equals(id))).write(
      const ModelsCompanion(routeStrategy: Value('round_robin')),
    );
    final model = (await repo.watchModels().first).single;

    final firsts = [
      for (var i = 0; i < 4; i++) router.order(model).first.channel.name,
    ];
    expect(firsts.toSet(), {'a.com', 'b.com'});
    expect(firsts[0], isNot(firsts[1]));
    expect(firsts[0], firsts[2]);
    expect(firsts[1], firsts[3]);

    final bId = model.routes
        .firstWhere((r) => r.channel.name == 'b.com')
        .channel
        .id;
    for (var i = 0; i < ModelRouter.failureThreshold; i++) {
      router.reportFailure(bId);
    }
    expect(router.isCoolingDown(bId), isTrue);
    expect([
      for (var i = 0; i < 3; i++) router.order(model).first.channel.name,
    ], everyElement('a.com'));
  });

  group('接力分析', () {
    /// 每个模型回答「<模型名>的结论」，并记录收到的最后一条用户消息。
    late Map<String, String> received;

    setUp(() {
      received = {};
      http.handler = (o) {
        final body = o.data as Map;
        final model = body['model'] as String;
        final msgs = (body['messages'] as List).cast<Map>();
        received[model] =
            msgs.lastWhere((m) => m['role'] == 'user')['content'] as String;
        return sse([chunk('$model的结论'), '[DONE]']);
      };
    });

    Future<String> chainConv(List<String> models) async {
      await channel('a.com', models);
      return chat.createConversation([
        for (final m in models) Participant(modelId: await modelId(m)),
      ], mode: ConversationMode.chain);
    }

    test('按顺序执行：第 n 步收到原始问题 + 第 n-1 步的结果；最后一步被采纳', () async {
      final conv = await chainConv(['A', 'B', 'C']);
      expect((await chat.conversation(conv))!.mode, 'chain');

      await chat.send(conv, '原始问题');
      final msgs = await settle(conv);
      final steps = msgs.where((m) => m.role == 'assistant').toList();

      expect(steps.map((m) => m.stepIndex), [0, 1, 2]);
      expect(steps.map((m) => m.status), everyElement(MsgStatus.done));
      // 严格按顺序请求。
      expect(http.requests.map((r) => (r.data as Map)['model']), [
        'A',
        'B',
        'C',
      ]);

      expect(received['A'], '原始问题');
      expect(
        received['B'],
        allOf(contains('原始问题'), contains('A的结论'), contains('第 1 步 · A')),
      );
      expect(
        received['C'],
        allOf(contains('原始问题'), contains('B的结论'), isNot(contains('A的结论'))),
      );

      expect(steps.where((m) => m.adopted).map(textOf), ['C的结论']);
    });

    test('下一轮对话的上下文只带最终结论', () async {
      final conv = await chainConv(['A', 'B']);
      await chat.send(conv, '第一问');
      await settle(conv);
      http.requests.clear();

      await chat.send(conv, '第二问');
      await settle(conv);
      final firstReq = (http.requests.first.data as Map)['messages'] as List;
      expect(firstReq.map((m) => (m as Map)['content']), [
        '第一问',
        'B的结论',
        '第二问',
      ]);
    });

    test('中间步骤失败：后续步骤中止，采纳最后一个成功的步骤', () async {
      final conv = await chainConv(['A', 'B', 'C']);
      final ok = http.handler;
      http.handler = (o) => (o.data as Map)['model'] == 'B'
          ? json({
              'error': {'message': 'bad'},
            }, 400)
          : ok(o);

      await chat.send(conv, 'q');
      final steps = (await settle(conv))
          .where((m) => m.role == 'assistant')
          .toList();
      expect(steps.map((m) => m.status), [
        MsgStatus.done,
        MsgStatus.error,
        MsgStatus.stopped,
      ]);
      expect(steps[2].error, contains('中止'));
      expect(http.requests.map((r) => (r.data as Map)['model']), ['A', 'B']);
      expect(steps.singleWhere((m) => m.adopted).stepIndex, 0);
    });

    test('从中间某步重新生成：该步及之后的步骤全部重跑，前面的不动', () async {
      final conv = await chainConv(['A', 'B', 'C']);
      await chat.send(conv, 'q');
      var steps = (await settle(conv))
          .where((m) => m.role == 'assistant')
          .toList();
      http.requests.clear();

      await chat.regenerate(steps[1].id);
      steps = (await settle(conv)).where((m) => m.role == 'assistant').toList();
      expect(http.requests.map((r) => (r.data as Map)['model']), ['B', 'C']);
      expect(steps.map((m) => m.status), everyElement(MsgStatus.done));
      expect(steps.singleWhere((m) => m.adopted).stepIndex, 2);
    });

    test('停止：当前步骤停止，排队中的步骤不再执行', () async {
      final conv = await chainConv(['A', 'B', 'C']);
      http.handler = (o) => sse([
        chunk('一'),
        chunk('二'),
        chunk('三'),
        '[DONE]',
      ], delay: const Duration(milliseconds: 60));
      await chat.send(conv, 'q');
      for (var i = 0; i < 100; i++) {
        final first = (await db.watchMessages(conv).first).firstWhere(
          (m) => m.stepIndex == 0,
        );
        if (textOf(first).isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await chat.stopConversation(conv);
      final steps = (await settle(conv))
          .where((m) => m.role == 'assistant')
          .toList();
      expect(steps.map((m) => m.status), everyElement(MsgStatus.stopped));
      expect(http.requests, hasLength(1));
    });

    test('单个参与者时退化为单模型模式', () async {
      await channel('a.com', ['A']);
      final conv = await chat.createConversation([
        Participant(modelId: await modelId('A')),
      ], mode: ConversationMode.chain);
      expect((await chat.conversation(conv))!.mode, 'single');
    });
  });

  test('DeepSeek 官方渠道开联网：改走 Anthropic 兼容接口，带 web_search 工具，回答带来源', () async {
    final id = await repo.saveChannel(
      name: 'DeepSeek',
      presetId: 'deepseek',
      protocol: ApiProtocol.openaiChat,
      baseUrl: 'https://api.deepseek.com',
      apiKey: 'sk-ds',
    );
    await repo.syncChannelModels(id, ['deepseek-v4-pro']);
    http.handler = (o) => o.uri.path.endsWith('/messages')
        ? sse([
            jsonEncode({
              'type': 'content_block_start',
              'index': 0,
              'content_block': {
                'type': 'server_tool_use',
                'id': 'srv_1',
                'name': 'web_search',
                'input': {'query': '今天新闻'},
              },
            }),
            jsonEncode({
              'type': 'content_block_start',
              'index': 1,
              'content_block': {
                'type': 'web_search_tool_result',
                'tool_use_id': 'srv_1',
                'content': [
                  {
                    'type': 'web_search_result',
                    'title': '新闻',
                    'url': 'https://news.example.com',
                    'encrypted_content': 'xx',
                  },
                ],
              },
            }),
            jsonEncode({
              'type': 'content_block_delta',
              'index': 2,
              'delta': {'type': 'text_delta', 'text': '今天的新闻是…'},
            }),
            jsonEncode({'type': 'message_stop'}),
          ])
        : sse([chunk('不联网'), '[DONE]']);
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('deepseek-v4-pro')),
    ]);

    // 不开联网：照常走 Chat Completions。
    await chat.send(conv, '你好');
    await settle(conv);
    expect(
      http.requests.last.uri.toString(),
      'https://api.deepseek.com/v1/chat/completions',
    );

    await chat.setWebSearch(conv, true);
    await chat.send(conv, '今天有什么新闻');
    final msgs = await settle(conv);
    final req = http.requests.last;
    expect(
      req.uri.toString(),
      'https://api.deepseek.com/anthropic/v1/messages',
    );
    expect(req.headers['x-api-key'], 'sk-ds');
    final body = req.data as Map;
    expect(body['model'], 'deepseek-v4-pro');
    expect((body['tools'] as List).single, containsPair('name', 'web_search'));
    final parts = ContentPart.decodeList(msgs.last.partsJson);
    expect(parts.text, '今天的新闻是…');
    expect(parts.whereType<CitationPart>().map((c) => c.url), [
      'https://news.example.com',
    ]);
  });

  group('中转站 GPT 联网', () {
    late String conv;
    setUp(() async {
      await channel('relay.com', ['gpt-4o']);
      conv = await chat.createConversation([
        Participant(modelId: await modelId('gpt-4o')),
      ]);
      await chat.setWebSearch(conv, true);
    });

    String ev(Map<String, Object?> m) => jsonEncode(m);

    test('中转站支持 Responses：改走 /responses，带 web_search 工具，回答带来源', () async {
      http.handler = (o) => o.uri.path.endsWith('/responses')
          ? sse([
              ev({
                'type': 'response.output_text.annotation.added',
                'annotation': {
                  'type': 'url_citation',
                  'url': 'https://a.com',
                  'title': 'A',
                },
              }),
              ev({'type': 'response.output_text.delta', 'delta': '联网回答'}),
              ev({'type': 'response.completed', 'response': {}}),
            ])
          : sse([chunk('不该走这里'), '[DONE]']);
      await chat.send(conv, '今天新闻');
      final msgs = await settle(conv);
      final req = http.requests.single;
      expect(req.uri.toString(), 'https://relay.com/v1/responses');
      expect((req.data as Map)['tools'], [
        {'type': 'web_search'},
      ]);
      final parts = ContentPart.decodeList(msgs.last.partsJson);
      expect(parts.text, '联网回答');
      expect(parts.citations.single.url, 'https://a.com');
      expect(parts.notices, isEmpty);
    });

    test('中转站不支持 Responses：自动退回普通对话并提示，之后不再尝试', () async {
      http.handler = (o) => o.uri.path.endsWith('/responses')
          ? json({
              'error': {'message': 'Invalid URL (POST /v1/responses)'},
            }, 404)
          : sse([chunk('普通回答'), '[DONE]']);
      await chat.send(conv, '今天新闻');
      var msgs = await settle(conv);
      expect(http.requests.map((r) => r.uri.path), [
        '/v1/responses',
        '/v1/chat/completions',
      ]);
      // 退回时不带联网参数（普通 GPT 在 Chat 接口带 web_search_options 会报错）。
      expect(
        (http.requests.last.data as Map).containsKey('web_search_options'),
        isFalse,
      );
      var last = msgs.last;
      expect(last.status, MsgStatus.done);
      final parts = ContentPart.decodeList(last.partsJson);
      expect(parts.text, '普通回答');
      expect(parts.notices.single.text, ChatService.noSearchNotice);

      // 第二次直接走 Chat，不再白白请求一次 /responses。
      await chat.send(conv, '再问一次');
      msgs = await settle(conv);
      expect(http.requests.last.uri.path, '/v1/chat/completions');
      expect(http.requests, hasLength(3));
      last = msgs.last;
      expect(ContentPart.decodeList(last.partsJson).notices, hasLength(1));
    });

    test('临时故障（5xx）不当作「不支持」：照常报错，下次仍走 Responses 联网', () async {
      http.handler = (o) => json({
        'error': {'message': 'bad gateway'},
      }, 502);
      await chat.send(conv, '新闻');
      var msgs = await settle(conv);
      expect(msgs.last.status, MsgStatus.error);
      expect(http.requests.map((r) => r.uri.path), ['/v1/responses']);

      http.handler = (o) => o.uri.path.endsWith('/responses')
          ? sse([
              jsonEncode({'type': 'response.output_text.delta', 'delta': '好'}),
              jsonEncode({'type': 'response.completed', 'response': {}}),
            ])
          : sse([chunk('不该走这里'), '[DONE]']);
      await chat.send(conv, '再试');
      msgs = await settle(conv);
      expect(http.requests.last.uri.path, '/v1/responses');
      expect(ContentPart.decodeList(msgs.last.partsJson).notices, isEmpty);
    });

    test('Key 无效等错误不退回，照常报错', () async {
      http.handler = (o) => json({
        'error': {'message': 'bad key'},
      }, 401);
      await chat.send(conv, 'hi');
      final msgs = await settle(conv);
      expect(msgs.last.status, MsgStatus.error);
      expect(http.requests, hasLength(1));
    });
  });

  test('搜索：标题和内容都能搜到，片段标出命中位置；通配符按字面匹配', () async {
    await channel('a.com', ['A']);
    http.handler = (_) => sse([chunk('相对论说的是时空是弯曲的。'), '[DONE]']);
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('A')),
    ]);
    await chat.send(conv, '讲讲相对论');
    await settle(conv);
    await chat.rename(conv, '物理问题');
    final other = await chat.createConversation([
      Participant(modelId: await modelId('A')),
    ], title: '100% 纯度');

    var hits = await chat.search('时空');
    expect(hits, hasLength(1));
    expect(hits.single.role, 'assistant');
    final h = hits.single;
    expect(
      h.snippet.substring(h.matchStart, h.matchStart + h.matchLength),
      '时空',
    );

    hits = await chat.search('物理');
    expect(hits.single.messageId, isNull, reason: '标题命中');

    hits = await chat.search('相对论');
    expect(hits.map((h) => h.role), containsAll(['user', 'assistant']));

    // % 是 LIKE 通配符，必须按字面匹配。
    hits = await chat.search('0%');
    expect(hits.single.conversation.id, other);
    expect(await chat.search('type'), isEmpty, reason: '不匹配 JSON 键名');
  });

  test('附件：文本文件并入问题，PDF 作为文件块原样发送；删除消息时一并删除文件', () async {
    await channel('a.com', ['A']);
    final conv = await chat.createConversation([
      Participant(modelId: await modelId('A')),
    ]);
    final pdf = Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 1, 2, 3]);
    await chat.send(
      conv,
      '看看这些',
      files: [
        PendingFile(
          Uint8List.fromList(utf8.encode('print(1)')),
          'a.py',
          'text/plain',
        ),
        PendingFile(pdf, '报告.pdf', 'application/pdf'),
      ],
    );
    final msgs = await settle(conv);
    final user = ContentPart.decodeList(msgs.first.partsJson);
    expect(user.files.map((f) => f.name), ['a.py', '报告.pdf']);

    final content =
        ((http.requests.single.data as Map)['messages'] as List).last['content']
            as List;
    expect(content.first['type'], 'text');
    expect(content.first['text'], contains('【附件：a.py】'));
    expect(content.first['text'], contains('print(1)'));
    expect(content.first['text'], endsWith('看看这些'));
    expect(content.last['type'], 'file');
    expect(content.last['file']['filename'], '报告.pdf');
    expect(
      content.last['file']['file_data'],
      startsWith('data:application/pdf;base64,'),
    );
    expect((await chat.conversation(conv))!.title, '看看这些');

    final dir = Directory('${tmp.path}/images');
    expect(dir.listSync(), hasLength(2));
    await chat.deleteMessage(msgs.first.id);
    expect(dir.listSync(), isEmpty);
  });

  group('上下文管理', () {
    late String conv;
    late List<List<Map>> sent;

    setUp(() async {
      sent = [];
      await channel('a.com', ['A']);
      conv = await chat.createConversation([
        Participant(modelId: await modelId('A')),
      ]);
      http.handler = (o) {
        final msgs = ((o.data as Map)['messages'] as List).cast<Map>();
        sent.add(msgs);
        final last = msgs.last['content'] as String;
        return sse([
          chunk(last.contains('压缩成一份摘要') ? '摘要：聊了一二三' : '答$last'),
          '[DONE]',
        ]);
      };
      for (final q in ['一', '二', '三', '四']) {
        await chat.send(conv, q);
        await settle(conv);
      }
    });

    List<String> lastContents() => [
      for (final m in sent.last) m['content'] as String,
    ];

    test('只携带最近 N 轮', () async {
      await chat.setOptions(conv, const ConversationOptions(contextTurns: 2));
      await chat.send(conv, '五');
      await settle(conv);
      expect(lastContents(), ['四', '答四', '五']);
    });

    test('立即压缩：早期对话换成摘要，保留最近两轮原文；可清除', () async {
      final before = await chat.contextTokens(conv);
      await chat.compress(conv);
      expect(lastContents().last, contains('压缩成一份摘要'));
      expect(lastContents().first, '一', reason: '压缩请求带上了早期对话');
      final opts = ConversationOptions.decode(
        (await chat.conversation(conv))!.optionsJson,
      );
      expect(opts.memory!.summary, '摘要：聊了一二三');
      expect(await chat.contextTokens(conv), lessThan(before + 20));

      await chat.send(conv, '五');
      await settle(conv);
      final c = lastContents();
      expect(c.first, contains('【之前对话的摘要】\n摘要：聊了一二三'));
      expect(c.sublist(2), ['三', '答三', '四', '答四', '五']);

      await chat.clearCompression(conv);
      await chat.send(conv, '六');
      await settle(conv);
      expect(lastContents().first, '一');
    });

    test('自动压缩：超过阈值时先压缩再回答，回答里提示', () async {
      await chat.setOptions(
        conv,
        const ConversationOptions(autoCompress: true),
      );
      await chat.send(conv, '长' * (ChatService.autoCompressTokens + 10));
      final msgs = await settle(conv);
      final opts = ConversationOptions.decode(
        (await chat.conversation(conv))!.optionsJson,
      );
      expect(opts.memory, isNotNull);
      final notice = ContentPart.decodeList(msgs.last.partsJson).notices;
      expect(notice.single.text, contains('自动'));
    });

    test('太短时不压缩', () async {
      final short = await chat.createConversation([
        Participant(modelId: await modelId('A')),
      ]);
      await chat.send(short, '只有一轮');
      await settle(short);
      expect(() => chat.compress(short), throwsA(isA<ApiException>()));
    });

    test('分支：复制到所选消息为止，消息 id 全新，继续对话只带分支前的内容', () async {
      final msgs = await chat.messagesOf(conv);
      final secondAnswer = msgs[3];
      final branch = await chat.branchFrom(secondAnswer.id);
      final copied = await chat.messagesOf(branch);
      expect(copied.map((m) => ContentPart.decodeList(m.partsJson).text), [
        '一',
        '答一',
        '二',
        '答二',
      ]);
      expect(
        copied
            .map((m) => m.id)
            .toSet()
            .intersection(msgs.map((m) => m.id).toSet()),
        isEmpty,
      );
      final c = (await chat.conversation(branch))!;
      expect(c.title, startsWith('分支：'));
      expect(
        c.participantsJson,
        (await chat.conversation(conv))!.participantsJson,
      );

      // 分支里继续对话，上下文只有分支前的内容。
      await chat.send(branch, '分支问题');
      await settle(branch);
      expect(lastContents(), ['一', '答一', '二', '答二', '分支问题']);
    });
  });

  group('裁判与辩论', () {
    /// 记录每次请求收到的最后一条用户消息（按顺序）。
    late List<(String, String)> calls;

    setUp(() {
      calls = [];
      http.handler = (o) {
        final body = o.data as Map;
        final model = body['model'] as String;
        final msgs = (body['messages'] as List).cast<Map>();
        calls.add((
          model,
          msgs.lastWhere((m) => m['role'] == 'user')['content'] as String,
        ));
        return sse([chunk('$model说${calls.length}'), '[DONE]']);
      };
    });

    test('裁判：各模型回答完后，裁判收到所有回答，其综合答案被采纳', () async {
      await channel('a.com', ['A', 'B', 'J']);
      final conv = await chat.createConversation([
        Participant(modelId: await modelId('A')),
        Participant(modelId: await modelId('B')),
      ], mode: ConversationMode.judge);
      await chat.setOptions(
        conv,
        ConversationOptions(judge: Participant(modelId: await modelId('J'))),
      );
      await chat.send(conv, '哪个对');
      final answers = (await settle(conv))
          .where((m) => m.role == 'assistant')
          .toList();
      expect(answers, hasLength(3));
      final judge = answers.singleWhere((m) => m.kind == MsgKind.judge);
      expect(judge.adopted, isTrue);
      expect(answers.where((m) => m.adopted), hasLength(1));
      // 裁判是最后一个请求，提示里包含原始问题和两个回答。
      final (model, prompt) = calls.last;
      expect(model, 'J');
      expect(prompt, contains('【原始问题】\n哪个对'));
      expect(prompt, contains('【回答 1：A】'));
      expect(prompt, contains('【回答 2：B】'));
      expect(prompt, contains('综合答案'));
    });

    test('辩论：按轮次交替发言，每次带上之前的发言，最后由总结者总结并被采纳', () async {
      await channel('a.com', ['A', 'B']);
      final conv = await chat.createConversation([
        Participant(modelId: await modelId('A')),
        Participant(modelId: await modelId('B')),
      ], mode: ConversationMode.debate);
      await chat.setOptions(conv, const ConversationOptions(rounds: 2));
      await chat.send(conv, '猫好还是狗好');
      final steps =
          (await settle(conv)).where((m) => m.role == 'assistant').toList()
            ..sort((a, b) => a.stepIndex!.compareTo(b.stepIndex!));
      expect(steps.map((m) => m.kind), [
        MsgKind.debate,
        MsgKind.debate,
        MsgKind.debate,
        MsgKind.debate,
        MsgKind.summary,
      ]);
      expect(calls.map((c) => c.$1), ['A', 'B', 'A', 'B', 'A']);
      expect(calls[0].$2, contains('先就这个问题给出你的观点'));
      expect(calls[1].$2, contains('A说1'));
      expect(calls[2].$2, contains('第 2 / 2 轮'));
      expect(calls[2].$2, contains('B说2'));
      expect(calls.last.$2, contains('总结者'));
      expect(calls.last.$2, contains('B说4'));
      expect(steps.last.adopted, isTrue);
    });
  });

  group('追问', () {
    test('当前对话追问：引用片段存为 QuotePart，发给模型时拼进问题', () async {
      await channel('a.com', ['A']);
      final conv = await chat.createConversation([
        Participant(modelId: await modelId('A')),
      ]);
      await chat.send(conv, '这是什么意思', quote: 'E=mc²');
      final msgs = await settle(conv);
      final parts = ContentPart.decodeList(msgs.first.partsJson);
      expect(parts.quote, 'E=mc²');
      expect(parts.text, '这是什么意思');
      final sent =
          ((http.requests.single.data as Map)['messages'] as List).last as Map;
      expect(sent['content'], contains('> E=mc²'));
      expect(sent['content'], endsWith('这是什么意思'));
    });

    test('新对话追问：用原 Agent 建对话；总结请求带上前文和选中内容；没发消息就丢弃', () async {
      await channel('a.com', ['A', 'B']);
      final conv = await chat.createConversation([
        Participant(modelId: await modelId('B')),
      ]);
      http.handler = (_) => sse([chunk('质能方程是…'), '[DONE]']);
      await chat.send(conv, '讲讲相对论');
      final answer = (await settle(conv)).last;

      final follow = await chat.createFollowUp(answer.id, '质能方程');
      final c = (await chat.conversation(follow))!;
      expect(c.title, '追问：质能方程');
      expect(
        Participant.decodeList(c.participantsJson).single.modelId,
        await modelId('B'),
      );

      http.handler = (_) => sse([chunk('用户问了'), chunk('相对论'), '[DONE]']);
      final out = await chat.summarize(answer.id, selection: '质能方程').toList();
      expect(out.last, '用户问了相对论');
      final body = http.requests.last.data as Map;
      expect(body['model'], 'B');
      final msgs = (body['messages'] as List).cast<Map>();
      expect(msgs.first['content'], '讲讲相对论');
      expect(msgs[1]['content'], '质能方程是…');
      expect(msgs.last['content'], contains('「质能方程」'));

      // 带上总结发第一条消息：总结存为 ContextPart。
      http.handler = (_) => sse([chunk('好'), '[DONE]']);
      await chat.send(follow, '展开说说', quote: '质能方程', context: '用户问了相对论');
      final first = (await settle(follow)).first;
      final parts = ContentPart.decodeList(first.partsJson);
      expect(parts.contextSummary, '用户问了相对论');
      expect(parts.promptText, startsWith('【背景：之前对话的总结】'));
      expect(await chat.discardIfEmpty(follow, force: true), isFalse);

      final unused = await chat.createFollowUp(answer.id, 'x');
      expect(await chat.discardIfEmpty(unused), isFalse, reason: '普通规则不删');
      expect(await chat.discardIfEmpty(unused, force: true), isTrue);
    });
  });

  test('离开空会话：什么都没做的被丢弃，选了模型 / 发过消息 / 改过名 / 置顶的保留', () async {
    await channel('a.com', ['A']);
    http.handler = (_) => sse([chunk('好'), '[DONE]']);
    final empty = await chat.createConversation(const []);
    expect(await chat.discardIfEmpty(empty), isTrue);
    expect(await chat.conversation(empty), isNull);

    final withModel = await chat.createConversation(const []);
    await chat.setParticipants(withModel, [
      Participant(modelId: await modelId('A')),
    ]);
    expect(await chat.discardIfEmpty(withModel), isFalse);

    final withMessage = await chat.createConversation([
      Participant(modelId: await modelId('A')),
    ]);
    await chat.send(withMessage, 'hi');
    await settle(withMessage);
    await chat.setParticipants(withMessage, const []);
    expect(await chat.discardIfEmpty(withMessage), isFalse);

    final renamed = await chat.createConversation(const []);
    await chat.rename(renamed, '我的对话');
    expect(await chat.discardIfEmpty(renamed), isFalse);

    final pinned = await chat.createConversation(const []);
    await chat.setPinned(pinned, true);
    expect(await chat.discardIfEmpty(pinned), isFalse);
  });

  test('buildChainPrompt：第一步原样，之后带上一步结果', () {
    expect(buildChainPrompt(question: 'Q', step: 0), 'Q');
    final p = buildChainPrompt(
      question: 'Q',
      step: 2,
      previousLabel: 'B',
      previousOutput: ' R ',
    );
    expect(p, contains('【原始问题】\nQ'));
    expect(p, contains('第 2 步 · B'));
    expect(p, contains('\nR\n'));
    expect(p, contains('第 3 步'));
  });
}
