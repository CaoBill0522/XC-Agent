import 'dart:convert';

import 'package:agent/core/api/api_error.dart';
import 'package:agent/core/api/channel_client.dart';
import 'package:agent/core/api/endpoint.dart';
import 'package:agent/core/api/protocol.dart';
import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/usage_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _Http implements HttpClientAdapter {
  _Http(this.handler);
  final ResponseBody Function(RequestOptions o) handler;
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

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    'content-type': ['application/json'],
  },
);

void main() {
  group('用量统计', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('按模型单价估算费用；没设单价的单独计数；可按时间筛选', () async {
      final now = DateTime.now();
      await db
          .into(db.models)
          .insert(
            ModelsCompanion.insert(
              id: 'a',
              displayName: 'A',
              inputPrice: const Value(2),
              outputPrice: const Value(8),
            ),
          );
      await db
          .into(db.models)
          .insert(ModelsCompanion.insert(id: 'b', displayName: 'B'));
      await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'c',
              title: 't',
              createdAt: now,
              updatedAt: now,
            ),
          );
      Future<void> msg(String id, String model, int i, int o, DateTime t) => db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              conversationId: 'c',
              role: 'assistant',
              modelId: Value(model),
              usageJson: Value(jsonEncode({'input': i, 'output': o})),
              createdAt: t,
            ),
          );
      await msg('1', 'a', 1000000, 500000, now);
      await msg('2', 'b', 2000, 1000, now);
      await msg('3', 'a', 1000000, 0, now.subtract(const Duration(days: 40)));

      final all = await UsageService(db).report();
      expect(all.total.requests, 3);
      expect(all.total.input, 2002000);
      expect(all.total.cost, closeTo(2 + 4 + 2, 1e-9));
      expect(all.total.unpriced, 1);
      expect(all.byModel.first.label, 'A');

      final recent = await UsageService(db)
          .report(since: now.subtract(const Duration(days: 30)));
      expect(recent.total.requests, 2);
      expect(recent.total.cost, closeTo(6, 1e-9));
    });

    test('token 数格式化', () {
      expect(formatTokens(999), '999');
      expect(formatTokens(1234), '1.2k');
      expect(formatTokens(56789), '57k');
      expect(formatTokens(1234567), '1.23M');
    });
  });

  group('渠道余额', () {
    ChannelEndpoint ep(String base) => ChannelEndpoint(
      protocol: ApiProtocol.openaiChat,
      baseUrl: base,
      apiKey: 'k',
    );

    test('DeepSeek 官方：user/balance', () async {
      final http = _Http(
        (o) => _json({
          'balance_infos': [
            {'currency': 'CNY', 'total_balance': '12.50'},
          ],
        }),
      );
      final c = ChannelClient(Dio()..httpClientAdapter = http);
      expect(
        await c.balance(ep('https://api.deepseek.com'), 'deepseek'),
        '余额 ¥12.50',
      );
      expect(
        http.requests.single.uri.toString(),
        'https://api.deepseek.com/user/balance',
      );
    });

    test('New API 中转站：额度减去已用', () async {
      final http = _Http(
        (o) => o.uri.path.endsWith('/subscription')
            ? _json({'hard_limit_usd': 20})
            : _json({'total_usage': 512}),
      );
      final c = ChannelClient(Dio()..httpClientAdapter = http);
      expect(
        await c.balance(ep('https://relay.example.com/v1'), 'custom'),
        r'余额 $14.88（额度 $20.00，已用 $5.12）',
      );
      expect(
        http.requests.first.uri.path,
        '/v1/dashboard/billing/subscription',
      );
    });

    test('不支持的中转站：友好提示', () async {
      final http = _Http((o) => _json({'error': 'not found'}, 404));
      final c = ChannelClient(Dio()..httpClientAdapter = http);
      expect(
        () => c.balance(ep('https://relay.example.com/v1'), 'custom'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '该渠道不支持查询余额'),
        ),
      );
    });
  });
}
