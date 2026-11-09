import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/chat/chat_types.dart';
import '../core/tools/calculator.dart';
import '../core/tools/mcp_client.dart';
import 'ids.dart';
import 'secure/key_store.dart';

/// ChatService 用的工具来源。
abstract class ToolProvider {
  /// 当前可用的工具定义；关闭工具调用时为空。
  Future<List<ToolSpec>> specs();

  /// 给用户看的名字。
  String labelOf(String name);

  Future<ToolResult> run(ToolCall call, {CancelToken? cancel});
}

class NoTools implements ToolProvider {
  const NoTools();
  @override
  Future<List<ToolSpec>> specs() async => const [];
  @override
  String labelOf(String name) => name;
  @override
  Future<ToolResult> run(ToolCall call, {CancelToken? cancel}) async =>
      ToolResult(
        callId: call.id,
        name: call.name,
        content: '工具不可用',
        isError: true,
      );
}

/// 内置工具：都在本机执行，iOS 上也能用。
enum BuiltinTool {
  fetchUrl(
    'fetch_url',
    '读取网页',
    '打开一个网址，返回网页的标题和正文文字。用于查看用户给的链接、或需要读取某个网页的具体内容时。',
    {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': '完整网址，以 http:// 或 https:// 开头',
        },
      },
      'required': ['url'],
    },
  ),
  time(
    'get_current_time',
    '当前时间',
    '获取用户设备上的当前日期、时间、星期和时区。涉及「今天」「现在」「几号」等问题时使用。',
    {'type': 'object', 'properties': <String, dynamic>{}},
  ),
  calculator(
    'calculate',
    '计算器',
    '精确计算数学表达式。支持 + - * / % ^ !、括号，以及 sqrt abs sin cos tan '
        'asin acos atan ln log log2 exp floor ceil round pow min max 和常量 pi e。'
        '三角函数用弧度。需要精确数值结果时使用，不要心算。',
    {
      'type': 'object',
      'properties': {
        'expression': {'type': 'string', 'description': '例如 (3.5+2)*sqrt(2)^3'},
      },
      'required': ['expression'],
    },
  );

  const BuiltinTool(this.id, this.label, this.description, this.parameters);
  final String id;
  final String label;
  final String description;
  final Map<String, dynamic> parameters;

  static BuiltinTool? byId(String id) {
    for (final t in values) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// 工具设置与执行：内置工具 + 远程 MCP 服务器。设置存在偏好里，
/// MCP 的访问令牌存在系统钥匙串。
class ToolService implements ToolProvider {
  /// [prefs] 延迟读取：没有覆盖偏好存储的测试里构造 ChatService 不会报错。
  ToolService(SharedPreferences Function() prefs, this._keys, {Dio? dio})
    : _prefsOf = prefs,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 5,
            ),
          );

  final SharedPreferences Function() _prefsOf;
  SharedPreferences get _prefs => _prefsOf();
  final KeyStore _keys;
  final Dio _dio;

  static const _enabledKey = 'tools_enabled';
  static const _disabledKey = 'tools_builtin_disabled';
  static const _serversKey = 'mcp_servers';

  /// 单个工具结果的最大长度（字符），太长会挤占上下文。
  static const maxResultChars = 12000;

  // ──────────────── 设置

  bool get enabled => _prefs.getBool(_enabledKey) ?? false;
  Future<void> setEnabled(bool on) => _prefs.setBool(_enabledKey, on);

  Set<String> get _disabled =>
      (_prefs.getStringList(_disabledKey) ?? const []).toSet();

  bool builtinEnabled(BuiltinTool t) => !_disabled.contains(t.id);

  Future<void> setBuiltinEnabled(BuiltinTool t, bool on) {
    final set = _disabled;
    on ? set.remove(t.id) : set.add(t.id);
    return _prefs.setStringList(_disabledKey, set.toList());
  }

  List<McpServerConfig> get servers {
    try {
      return [
        for (final j
            in jsonDecode(_prefs.getString(_serversKey) ?? '[]') as List)
          McpServerConfig.fromJson(j as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveServers(List<McpServerConfig> list) => _prefs.setString(
    _serversKey,
    jsonEncode([for (final s in list) s.toJson()]),
  );

  static String _tokenKey(String id) => 'mcp:$id';

  Future<String?> tokenOf(String serverId) => _keys.read(_tokenKey(serverId));

  /// 新增或更新服务器。[token] 为 null 表示不改令牌，空字符串表示删除令牌。
  Future<McpServerConfig> saveServer(McpServerConfig s, {String? token}) async {
    final list = servers;
    final i = list.indexWhere((x) => x.id == s.id);
    i < 0 ? list.add(s) : list[i] = s;
    await _saveServers(list);
    if (token != null) {
      token.trim().isEmpty
          ? await _keys.delete(_tokenKey(s.id))
          : await _keys.write(_tokenKey(s.id), token.trim());
    }
    _clients.remove(s.id);
    _cache.remove(s.id);
    return s;
  }

  Future<void> deleteServer(String id) async {
    await _saveServers([
      for (final s in servers)
        if (s.id != id) s,
    ]);
    await _keys.delete(_tokenKey(id));
    _clients.remove(id);
    _cache.remove(id);
  }

  static McpServerConfig newServer(String name, String url) =>
      McpServerConfig(id: newId(), name: name.trim(), url: url.trim());

  // ──────────────── MCP

  final _clients = <String, McpClient>{};
  final _cache = <String, (DateTime, List<McpTool>)>{};

  /// 模型看到的工具名 → (服务器 id, 服务器上的工具名)。
  final _mcpNames = <String, (String, String)>{};
  final _labels = <String, String>{};

  Future<McpClient> _client(McpServerConfig s) async =>
      _clients[s.id] ??= McpClient(s.url, token: await tokenOf(s.id));

  /// 连接服务器并列出工具（设置页「测试」也用它）。结果缓存 5 分钟。
  Future<List<McpTool>> toolsOf(
    McpServerConfig s, {
    bool refresh = false,
  }) async {
    final hit = _cache[s.id];
    if (!refresh &&
        hit != null &&
        DateTime.now().difference(hit.$1) < const Duration(minutes: 5)) {
      return hit.$2;
    }
    final tools = await (await _client(s)).listTools();
    _cache[s.id] = (DateTime.now(), tools);
    return tools;
  }

  /// 工具名只能含字母数字下划线横线，最长 64（OpenAI 的限制）。
  static String sanitizeName(String raw) {
    var s = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    s = s.replaceAll(RegExp(r'_+'), '_');
    if (s.isEmpty) s = 'tool';
    return s.length > 64 ? s.substring(0, 64) : s;
  }

  // ──────────────── ToolProvider

  @override
  Future<List<ToolSpec>> specs() async {
    if (!enabled) return const [];
    final out = <ToolSpec>[
      for (final t in BuiltinTool.values)
        if (builtinEnabled(t))
          ToolSpec(
            name: t.id,
            description: t.description,
            parameters: t.parameters,
          ),
    ];
    final used = {for (final s in out) s.name};
    for (final server in servers.where((s) => s.enabled)) {
      final List<McpTool> tools;
      try {
        tools = await toolsOf(server);
      } catch (_) {
        // 某个服务器连不上时不影响其它工具和正常回答。
        continue;
      }
      final prefix = sanitizeName(server.name).toLowerCase();
      for (final t in tools) {
        var name = sanitizeName('${prefix}_${t.name}');
        for (var n = 2; used.contains(name); n++) {
          name = sanitizeName('${prefix}_${t.name}_$n');
        }
        used.add(name);
        _mcpNames[name] = (server.id, t.name);
        _labels[name] = '${server.name} · ${t.name}';
        out.add(
          ToolSpec(
            name: name,
            description: t.description.isEmpty ? t.name : t.description,
            parameters: t.inputSchema,
          ),
        );
      }
    }
    return out;
  }

  @override
  String labelOf(String name) =>
      BuiltinTool.byId(name)?.label ?? _labels[name] ?? name;

  @override
  Future<ToolResult> run(ToolCall call, {CancelToken? cancel}) async {
    ToolResult done(String content, {bool error = false}) => ToolResult(
      callId: call.id,
      name: call.name,
      content: _clip(content),
      isError: error,
    );
    final args = call.argumentsMap;
    try {
      switch (BuiltinTool.byId(call.name)) {
        case BuiltinTool.fetchUrl:
          return done(await fetchPage('${args['url'] ?? ''}', cancel: cancel));
        case BuiltinTool.time:
          return done(describeNow(DateTime.now()));
        case BuiltinTool.calculator:
          final expr = '${args['expression'] ?? ''}';
          return done('$expr = ${formatNumber(evaluateExpression(expr))}');
        case null:
          break;
      }
      final target = _mcpNames[call.name];
      final server = servers.where((s) => s.id == target?.$1).firstOrNull;
      if (target == null || server == null) {
        return done('没有名为 ${call.name} 的工具', error: true);
      }
      final (text, isError) = await (await _client(server))
          .callTool(target.$2, args, cancel: cancel);
      return done(text.isEmpty ? '（没有返回内容）' : text, error: isError);
    } on FormatException catch (e) {
      return done('计算失败：${e.message}', error: true);
    } on McpException catch (e) {
      return done(e.message, error: true);
    } on DioException catch (e) {
      return done('请求失败：${e.message ?? e.type.name}', error: true);
    } catch (e) {
      return done('执行失败：$e', error: true);
    }
  }

  static String _clip(String s) => s.length <= maxResultChars
      ? s
      : '${s.substring(0, maxResultChars)}\n…（内容过长，已截断）';

  // ──────────────── 内置工具实现

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  static String describeNow(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final off = t.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final h = two(off.inHours.abs());
    final m = two(off.inMinutes.abs() % 60);
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
        '星期${_weekdays[t.weekday - 1]}（时区 ${t.timeZoneName}，UTC$sign$h:$m）';
  }

  /// 网页最多读取的字节数。
  static const _maxPageBytes = 3 * 1024 * 1024;

  Future<String> fetchPage(String url, {CancelToken? cancel}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const FormatException('网址无效，需要以 http:// 或 https:// 开头');
    }
    final res = await _dio.getUri<ResponseBody>(
      uri,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'user-agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 XC-Agent',
          'accept': 'text/html,application/xhtml+xml,text/plain,*/*;q=0.8',
          'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      ),
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res.data!.stream) {
      bytes.add(chunk);
      if (bytes.length > _maxPageBytes) break;
    }
    final body = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    final type = res.headers.value('content-type') ?? '';
    if (type.contains('html') || body.trimLeft().startsWith('<')) {
      final (title, text) = htmlToText(body);
      return '网址：${res.realUri}\n${title.isEmpty ? '' : '标题：$title\n'}\n$text';
    }
    return '网址：${res.realUri}\n\n$body';
  }
}

/// 粗略把 HTML 转成正文文字：去掉脚本 / 样式 / 导航，块级标签换行。返回 (标题, 正文)。
(String, String) htmlToText(String html) {
  String decode(String s) => s
      .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m[2]!, radix: m[1]!.isEmpty ? 10 : 16);
        return code == null || code > 0x10FFFF ? '' : String.fromCharCode(code);
      })
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  final title = RegExp(
    r'<title[^>]*>([\s\S]*?)</title>',
    caseSensitive: false,
  ).firstMatch(html)?[1];
  var s = html
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(
        RegExp(
          r'<(script|style|noscript|svg|template|iframe|head|nav|footer)\b[\s\S]*?</\1\s*>',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n- ')
      .replaceAll(
        RegExp(
          r'</(p|div|section|article|h[1-6]|tr|table|ul|ol|blockquote|pre|header|main)>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = decode(s)
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ').trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return (decode(title ?? '').trim(), s);
}
