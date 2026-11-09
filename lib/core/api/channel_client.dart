import 'dart:convert';

import 'package:dio/dio.dart';

import 'api_error.dart';
import 'endpoint.dart';
import 'protocol.dart';
import '../../l10n/tr.dart';

/// 云端模型列表中的一项。
class RemoteModel {
  const RemoteModel(this.id, {this.displayName, this.ownedBy});

  final String id;
  final String? displayName;
  final String? ownedBy;
}

class ConnectionTestResult {
  const ConnectionTestResult({required this.latency, required this.message});

  final Duration latency;
  final String message;
}

/// 渠道级请求：拉取模型列表、测试连通性。
class ChannelClient {
  ChannelClient([Dio? dio])
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

  final Dio _dio;

  /// 拉取模型列表。Anthropic 格式会自动翻页。
  Future<List<RemoteModel>> listModels(ChannelEndpoint endpoint) async {
    final models = <RemoteModel>[];
    String? afterId;
    // 翻页上限，防止异常接口死循环。
    for (var page = 0; page < 20; page++) {
      final Response<Object?> res;
      try {
        res = await _dio.getUri(
          endpoint.modelsUrl.replace(
            queryParameters: {
              if (!endpoint.protocol.isOpenAI) 'limit': '1000',
              'after_id': ?afterId,
            },
          ),
          options: Options(headers: endpoint.headers),
        );
      } on DioException catch (e) {
        throw ApiException.fromDio(e);
      }
      final parsed = parseModelList(res.data);
      models.addAll(parsed.models);
      if (!parsed.hasMore || parsed.lastId == null) break;
      afterId = parsed.lastId;
    }

    // 去重并排序，方便浏览。
    final seen = <String>{};
    return [
      for (final m in models)
        if (seen.add(m.id)) m,
    ]..sort((a, b) => a.id.compareTo(b.id));
  }

  /// 是否能查询余额：DeepSeek 官方，或 New API / One API 一类中转站。
  static bool supportsBalance(String presetId) =>
      presetId == 'deepseek' || presetId == 'custom';

  /// 查询余额，返回给人看的一句话（如「余额 ¥12.34」）。
  Future<String> balance(ChannelEndpoint endpoint, String presetId) async {
    final opts = Options(
      headers: {
        ...endpoint.headers,
        'Authorization': 'Bearer ${endpoint.apiKey}',
      },
    );
    const usd = r'$';
    try {
      if (isDeepSeekOfficial(presetId: presetId, baseUrl: endpoint.baseUrl)) {
        final res = await _dio.get<Object?>(
          'https://api.deepseek.com/user/balance',
          options: opts,
        );
        final infos = (res.data as Map?)?['balance_infos'] as List?;
        if (infos == null || infos.isEmpty) throw ApiException(tr('返回格式不认识'));
        return infos
            .whereType<Map>()
            .map((i) {
              final sym = i['currency'] == 'CNY' ? '¥' : usd;
              return trArgs('余额 {0}{1}', [sym, i['total_balance']]);
            })
            .join('，');
      }
      // New API / One API 兼容 OpenAI 旧版的账单接口：额度（美元）与已用（美分）。
      final base = endpoint.protocol.isOpenAI ? '' : '/v1';
      final sub = await _dio.getUri<Object?>(
        endpoint.url('$base/dashboard/billing/subscription'),
        options: opts,
      );
      final limit = ((sub.data as Map?)?['hard_limit_usd'] as num?)?.toDouble();
      if (limit == null) throw ApiException(tr('该渠道不支持查询余额'));
      final now = DateTime.now();
      String d(DateTime t) =>
          '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      final usage = await _dio.getUri<Object?>(
        endpoint
            .url('$base/dashboard/billing/usage')
            .replace(
              queryParameters: {
                'start_date': d(now.subtract(const Duration(days: 99))),
                'end_date': d(now.add(const Duration(days: 1))),
              },
            ),
        options: opts,
      );
      final used =
          (((usage.data as Map?)?['total_usage'] as num?)?.toDouble() ?? 0) /
          100;
      String money(double v) => '$usd${v.toStringAsFixed(2)}';
      // 不限额度的令牌通常返回一个极大的额度。
      if (limit >= 1e8) return trArgs('已用 {0}（额度不限）', [money(used)]);
      return trArgs('余额 {0}（额度 {1}，已用 {2}）', [
        money(limit - used),
        money(limit),
        money(used),
      ]);
    } on DioException catch (e) {
      final api = ApiException.fromDio(e);
      if (api.isNotFound) throw ApiException(tr('该渠道不支持查询余额'));
      throw api;
    }
  }

  /// 用一个最小请求测试连通性和 Key 是否可用（会消耗极少量 token）。
  Future<ConnectionTestResult> testChat(
    ChannelEndpoint endpoint,
    String model,
  ) async {
    final body = switch (endpoint.protocol) {
      ApiProtocol.openaiChat => {
        'model': model,
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
        'max_tokens': 8,
      },
      // Responses API 的 max_output_tokens 最小为 16。
      ApiProtocol.openaiResponses => {
        'model': model,
        'input': 'hi',
        'max_output_tokens': 16,
      },
      ApiProtocol.anthropic => {
        'model': model,
        'max_tokens': 8,
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
      },
    };

    final sw = Stopwatch()..start();
    try {
      await _dio.postUri(
        endpoint.chatUrl,
        data: body,
        options: Options(
          headers: {...endpoint.headers, 'content-type': 'application/json'},
        ),
      );
    } on DioException catch (e) {
      final err = ApiException.fromDio(e);
      // 推理模型可能因 max_tokens 太小或不支持 max_tokens 而报 400，
      // 但能走到参数校验，说明连接和 Key 都没问题。
      final detail = (err.detail ?? '').toLowerCase();
      if (err.statusCode == 400 &&
          RegExp(r'max_(output_|completion_)?tokens').hasMatch(detail)) {
        sw.stop();
        return ConnectionTestResult(
          latency: sw.elapsed,
          message: tr('连接正常（模型拒绝了过短的测试请求）'),
        );
      }
      throw err;
    }
    sw.stop();
    return ConnectionTestResult(latency: sw.elapsed, message: tr('连接正常'));
  }
}

class ParsedModelList {
  const ParsedModelList(this.models, {this.hasMore = false, this.lastId});

  final List<RemoteModel> models;
  final bool hasMore;
  final String? lastId;
}

/// 解析各家 `/models` 响应：
/// - OpenAI 及兼容：`{"object":"list","data":[{"id":..,"owned_by":..}]}`
/// - Anthropic：`{"data":[{"id":..,"display_name":..}],"has_more":..,"last_id":..}`
/// - 部分中转站：直接返回数组，或 `{"models":[...]}`
ParsedModelList parseModelList(Object? body) {
  Object? json = body;
  if (body is String) {
    try {
      json = jsonDecode(body);
    } catch (_) {
      throw ApiException(
        tr('模型列表格式无法识别'),
        detail: body.length > 200 ? body.substring(0, 200) : body,
      );
    }
  }

  List? items;
  var hasMore = false;
  String? lastId;
  if (json is List) {
    items = json;
  } else if (json is Map) {
    items = (json['data'] ?? json['models']) as List?;
    hasMore = json['has_more'] == true;
    lastId = json['last_id'] as String?;
  }
  if (items == null) {
    throw ApiException(tr('模型列表格式无法识别'));
  }

  final models = <RemoteModel>[];
  for (final item in items) {
    if (item is String) {
      models.add(RemoteModel(item));
    } else if (item is Map) {
      final id = (item['id'] ?? item['name'] ?? item['model']) as String?;
      if (id == null || id.isEmpty) continue;
      models.add(
        RemoteModel(
          id,
          displayName: item['display_name'] as String?,
          ownedBy: item['owned_by'] as String?,
        ),
      );
    }
  }
  return ParsedModelList(models, hasMore: hasMore, lastId: lastId);
}
