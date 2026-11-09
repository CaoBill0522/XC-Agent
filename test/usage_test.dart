import 'dart:convert';

import 'package:agent/data/db/app_database.dart';
import 'package:agent/data/usage_service.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('用量统计', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('按模型、按渠道汇总 token 用量；可按时间筛选', () async {
      final now = DateTime.now();
      await db
          .into(db.models)
          .insert(
            ModelsCompanion.insert(
              id: 'a',
              displayName: 'A',
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
      expect(all.total.output, 501000);
      expect(all.byModel, hasLength(2));
      expect(all.byModel.first.label, 'A');

      final recent = await UsageService(db)
          .report(since: now.subtract(const Duration(days: 30)));
      expect(recent.total.requests, 2);
      expect(recent.total.input, 1002000);
    });

    test('token 数格式化', () {
      expect(formatTokens(999), '999');
      expect(formatTokens(1234), '1.2k');
      expect(formatTokens(56789), '57k');
      expect(formatTokens(1234567), '1.23M');
    });
  });
}
