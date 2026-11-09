import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../chat/chat_types.dart';
import 'adapters/adapter.dart';
import 'api_error.dart';
import 'endpoint.dart';
import 'sse.dart';
import '../../l10n/tr.dart';

/// 生成的图片。
class GeneratedImage {
  const GeneratedImage(this.bytes, this.mime, {this.revisedPrompt});
  final Uint8List bytes;
  final String mime;
  final String? revisedPrompt;
}

/// 对话 / 生图请求。
class ChatClient {
  ChatClient([Dio? dio])
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              // 流式输出两段数据之间的最长间隔（推理模型思考时可能较久）。
              receiveTimeout: const Duration(minutes: 5),
            ),
          );

  final Dio _dio;

  /// 流式对话。[cancel] 用于停止生成。
  Stream<ChatEvent> stream(
    ChannelEndpoint endpoint,
    ChatRequest req, {
    CancelToken? cancel,
  }) async* {
    final adapter = ProtocolAdapter.of(endpoint.protocol);
    final Response<ResponseBody> res;
    try {
      res = await _dio.postUri<ResponseBody>(
        endpoint.chatUrl,
        data: adapter.buildBody(req),
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          headers: {
            ...endpoint.headers,
            'content-type': 'application/json',
            'accept': 'text/event-stream',
          },
        ),
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }

    final body = res.data!;
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw await _errorFromBody(res, body);
    }

    final contentType = res.headers.value('content-type') ?? '';
    try {
      if (contentType.contains('application/json')) {
        final text = await utf8.decodeStream(body.stream);
        yield* Stream.fromIterable(
          adapter.parseFull(jsonDecode(text) as Map<String, dynamic>),
        );
        return;
      }
      await for (final e in parseSse(body.stream)) {
        for (final ev in adapter.parseEvent(e)) {
          yield ev;
        }
      }
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// OpenAI 兼容的生图接口。带参考图且模型支持时走 /images/edits。
  Future<List<GeneratedImage>> generateImage(
    ChannelEndpoint endpoint, {
    required String model,
    required String prompt,
    List<InlineImage> references = const [],
    String? size,
    CancelToken? cancel,
  }) async {
    if (!endpoint.protocol.isOpenAI) {
      throw ApiException(tr('该渠道使用 Anthropic 协议，不支持生图接口'));
    }
    final isGptImage = model.toLowerCase().contains('gpt-image');
    final Response<Object?> res;
    try {
      if (references.isNotEmpty && isGptImage) {
        final form = FormData.fromMap({
          'model': model,
          'prompt': prompt,
          'size': ?size,
          'image[]': [
            for (final (i, r) in references.indexed)
              MultipartFile.fromBytes(
                base64Decode(r.base64),
                filename: 'image$i.${r.mime.split('/').last}',
                contentType: DioMediaType.parse(r.mime),
              ),
          ],
        });
        res = await _dio.postUri(
          endpoint.url('/images/edits'),
          data: form,
          cancelToken: cancel,
          options: Options(headers: endpoint.headers),
        );
      } else {
        res = await _dio.postUri(
          endpoint.url('/images/generations'),
          cancelToken: cancel,
          data: {
            'model': model,
            'prompt': prompt,
            'n': 1,
            'size': ?size,
            // gpt-image 系列始终返回 b64，传 response_format 反而报错。
            if (!isGptImage) 'response_format': 'b64_json',
          },
          options: Options(
            headers: {...endpoint.headers, 'content-type': 'application/json'},
          ),
        );
      }
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }

    final json = res.data is String ? jsonDecode(res.data as String) : res.data;
    final data = ((json is Map) ? json['data'] : null) as List?;
    if (data == null || data.isEmpty) {
      throw ApiException(tr('生图接口没有返回图片'), detail: jsonEncode(json));
    }
    final out = <GeneratedImage>[];
    for (final d in data.whereType<Map>()) {
      final revised = d['revised_prompt'] as String?;
      if (d['b64_json'] case final String b64) {
        out.add(
          GeneratedImage(
            base64Decode(b64),
            'image/png',
            revisedPrompt: revised,
          ),
        );
      } else if (d['url'] case final String url) {
        try {
          final img = await _dio.get<List<int>>(
            url,
            cancelToken: cancel,
            options: Options(responseType: ResponseType.bytes),
          );
          final mime = img.headers.value('content-type') ?? 'image/png';
          out.add(
            GeneratedImage(
              Uint8List.fromList(img.data!),
              mime,
              revisedPrompt: revised,
            ),
          );
        } on DioException catch (e) {
          throw ApiException.fromDio(e);
        }
      }
    }
    return out;
  }

  Future<ApiException> _errorFromBody(Response res, ResponseBody body) async {
    String text = '';
    try {
      text = await utf8.decodeStream(body.stream);
    } catch (_) {}
    return ApiException.fromDio(
      DioException.badResponse(
        statusCode: res.statusCode ?? 0,
        requestOptions: res.requestOptions,
        response: Response(
          requestOptions: res.requestOptions,
          statusCode: res.statusCode,
          data: text,
        ),
      ),
    );
  }
}
