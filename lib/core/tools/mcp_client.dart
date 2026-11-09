import 'dart:convert';

import 'package:dio/dio.dart';

import '../api/sse.dart';

/// 远程 MCP 服务器（Streamable HTTP 传输）。iOS / Android 不能启动本地进程，
/// 只支持这种通过网址连接的服务器；桌面端同样走这条路。
class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String url;
  final bool enabled;

  McpServerConfig copyWith({String? name, String? url, bool? enabled}) =>
      McpServerConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'enabled': enabled,
  };

  factory McpServerConfig.fromJson(Map<String, dynamic> j) => McpServerConfig(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'MCP',
    url: j['url'] as String? ?? '',
    enabled: j['enabled'] != false,
  );
}

class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
}

class McpException implements Exception {
  McpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一个 MCP 服务器的 JSON-RPC 会话。
class McpClient {
  McpClient(this.url, {this.token, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(minutes: 2),
            ),
          );

  final String url;
  final String? token;
  final Dio _dio;

  static const protocolVersion = '2025-06-18';

  String? _session;
  bool _initialized = false;
  int _nextId = 1;

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'accept': 'application/json, text/event-stream',
    'mcp-protocol-version': protocolVersion,
    if (token case final t? when t.isNotEmpty) 'authorization': 'Bearer $t',
    'mcp-session-id': ?_session,
  };

  Future<void> _ensureInit(CancelToken? cancel) async {
    if (_initialized) return;
    await _rpc(
      'initialize',
      {
        'protocolVersion': protocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'XC-Agent', 'version': '1.0'},
      },
      cancel: cancel,
      init: true,
    );
    _initialized = true;
    await _notify('notifications/initialized');
  }

  Future<List<McpTool>> listTools({CancelToken? cancel}) async {
    await _ensureInit(cancel);
    final tools = <McpTool>[];
    String? cursor;
    for (var page = 0; page < 10; page++) {
      final r = await _rpc('tools/list', {'cursor': ?cursor}, cancel: cancel);
      for (final t in (r['tools'] as List? ?? const [])) {
        if (t is! Map || t['name'] is! String) continue;
        final schema = t['inputSchema'];
        tools.add(
          McpTool(
            name: t['name'] as String,
            description: t['description'] as String? ?? '',
            inputSchema: schema is Map<String, dynamic>
                ? schema
                : {'type': 'object', 'properties': <String, dynamic>{}},
          ),
        );
      }
      cursor = r['nextCursor'] as String?;
      if (cursor == null) break;
    }
    return tools;
  }

  /// 调用工具，返回 (文字结果, 是否出错)。
  Future<(String, bool)> callTool(
    String name,
    Map<String, dynamic> args, {
    CancelToken? cancel,
  }) async {
    await _ensureInit(cancel);
    final r = await _rpc('tools/call', {
      'name': name,
      'arguments': args,
    }, cancel: cancel);
    final out = StringBuffer();
    for (final c in (r['content'] as List? ?? const [])) {
      if (c is! Map) continue;
      switch (c['type']) {
        case 'text':
          out.writeln(c['text']);
        case 'resource':
          final res = c['resource'];
          if (res is Map && res['text'] is String) out.writeln(res['text']);
        case 'image' || 'audio':
          out.writeln('[${c['type']}: ${c['mimeType'] ?? ''}]');
        case 'resource_link':
          out.writeln('${c['name'] ?? ''} ${c['uri'] ?? ''}');
      }
    }
    if (out.isEmpty && r['structuredContent'] != null) {
      out.write(jsonEncode(r['structuredContent']));
    }
    return (out.toString().trim(), r['isError'] == true);
  }

  Future<void> _notify(String method) async {
    try {
      await _dio.post<Object?>(
        url,
        data: {'jsonrpc': '2.0', 'method': method},
        options: Options(headers: _headers, validateStatus: (_) => true),
      );
    } on DioException {
      // 通知没有响应要求，失败也不影响后续调用。
    }
  }

  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, dynamic> params, {
    CancelToken? cancel,
    bool init = false,
  }) async {
    final id = _nextId++;
    final Response<ResponseBody> res;
    try {
      res = await _dio.post<ResponseBody>(
        url,
        data: {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params},
        cancelToken: cancel,
        options: Options(
          headers: _headers,
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw McpException(
        e.type == DioExceptionType.cancel ? '已取消' : '无法连接 MCP 服务器：${e.message}',
      );
    }
    final status = res.statusCode ?? 0;
    // 会话过期：重新初始化一次再试。
    if (status == 404 && _session != null && !init) {
      _session = null;
      _initialized = false;
      await _ensureInit(cancel);
      return _rpc(method, params, cancel: cancel);
    }
    if (res.headers.value('mcp-session-id') case final s?) _session = s;
    final body = res.data!;
    if (status == 401 || status == 403) {
      throw McpException('MCP 服务器拒绝访问（$status），请检查令牌');
    }
    if (status < 200 || status >= 300) {
      final text = await utf8.decodeStream(body.stream).catchError((_) => '');
      throw McpException(
        'MCP 服务器返回 $status${text.isEmpty ? '' : '：${_short(text)}'}',
      );
    }

    final type = res.headers.value('content-type') ?? '';
    Map<String, dynamic>? message;
    if (type.contains('text/event-stream')) {
      await for (final e in parseSse(body.stream)) {
        final j = _decode(e.data);
        if (j != null && j['id'] == id) {
          message = j;
          break;
        }
      }
    } else {
      final j = _decode(await utf8.decodeStream(body.stream));
      if (j != null) message = j;
    }
    if (message == null) throw McpException('MCP 服务器没有返回结果');
    if (message['error'] case final Map err) {
      throw McpException('MCP 错误：${err['message'] ?? err}');
    }
    final result = message['result'];
    return result is Map<String, dynamic> ? result : {};
  }

  static Map<String, dynamic>? _decode(String s) {
    try {
      final j = jsonDecode(s);
      if (j is Map<String, dynamic>) return j;
      // 批量响应：取第一条。
      if (j is List && j.firstOrNull is Map<String, dynamic>) {
        return j.first as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static String _short(String s) =>
      s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
