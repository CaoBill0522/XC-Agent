import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tools/mcp_client.dart';
import '../../data/providers.dart';
import '../../data/tool_service.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/settings_widgets.dart';
import '../../l10n/tr.dart';

/// 工具调用设置：总开关、内置工具、远程 MCP 服务器。
class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({super.key});

  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  ToolService get _tools => ref.read(toolServiceProvider);

  Future<void> _edit([McpServerConfig? s]) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => McpServerPage(server: s)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final t = _tools;
    final on = t.enabled;
    return SettingsScaffold(
      title: tr('工具'),
      children: [
        SettingsGroup(
          children: [
            MiuixSwitchPreference(
              title: tr('工具调用'),
              summary: tr('让模型在回答时使用下面的工具（需要模型支持函数调用）'),
              value: on,
              onChanged: (v) async {
                await t.setEnabled(v);
                setState(() {});
              },
            ),
          ],
        ),
        SettingsGroup(
          title: tr('内置工具（在本机执行）'),
          children: [
            for (final b in BuiltinTool.values)
              MiuixSwitchPreference(
                title: b.label,
                summary: switch (b) {
                  BuiltinTool.fetchUrl => tr('打开网址，读取网页正文'),
                  BuiltinTool.time => tr('获取当前日期、时间和时区'),
                  BuiltinTool.calculator => tr('精确计算数学表达式'),
                },
                value: t.builtinEnabled(b),
                enabled: on,
                onChanged: (v) async {
                  await t.setBuiltinEnabled(b, v);
                  setState(() {});
                },
              ),
          ],
        ),
        SettingsGroup(
          title: tr('MCP 服务器'),
          children: [
            for (final s in t.servers)
              MiuixArrowPreference(
                title: s.name,
                summary: s.enabled ? s.url : trArgs('已停用 · {0}', [s.url]),
                onClick: () => _edit(s),
              ),
            MiuixArrowPreference(
              title: tr('添加 MCP 服务器'),
              startAction: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: MiuixIcon(
                  vector: AppIcons.add,
                  size: 22,
                  tint: colors.primary,
                ),
              ),
              onClick: _edit,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
          child: MiuixText(
            tr(
              '支持通过网址连接的 MCP 服务器（Streamable HTTP），手机和电脑都能用。需要在电脑上启动程序的本地 MCP（stdio）在 iOS 上无法运行。\n\n模型调用工具前不会再问你；只添加你信任的服务器。',
            ),
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
        ),
      ],
    );
  }
}

class McpServerPage extends ConsumerStatefulWidget {
  const McpServerPage({super.key, this.server});

  final McpServerConfig? server;

  @override
  ConsumerState<McpServerPage> createState() => _McpServerPageState();
}

class _McpServerPageState extends ConsumerState<McpServerPage> {
  late final _name = TextEditingController(text: widget.server?.name);
  late final _url = TextEditingController(text: widget.server?.url);
  final _token = TextEditingController();
  late bool _enabled = widget.server?.enabled ?? true;
  final _snackbar = MiuixSnackbarHostState();
  bool _testing = false;
  List<McpTool>? _found;
  bool _tokenLoaded = false;

  ToolService get _tools => ref.read(toolServiceProvider);

  @override
  void initState() {
    super.initState();
    if (widget.server case final s?) {
      _tools.tokenOf(s.id).then((t) {
        if (!mounted) return;
        _token.text = t ?? '';
        _tokenLoaded = true;
      });
    } else {
      _tokenLoaded = true;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    _snackbar.dispose();
    super.dispose();
  }

  McpServerConfig? _config() {
    final url = _url.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      _snackbar.showSnackbar(tr('请填写以 http:// 或 https:// 开头的网址'));
      return null;
    }
    final name = _name.text.trim().isEmpty ? uri.host : _name.text.trim();
    final base = widget.server ?? ToolService.newServer(name, url);
    return base.copyWith(name: name, url: url, enabled: _enabled);
  }

  Future<McpServerConfig?> _save() async {
    final c = _config();
    if (c == null) return null;
    return _tools.saveServer(c, token: _tokenLoaded ? _token.text : null);
  }

  Future<void> _test() async {
    final c = await _save();
    if (c == null) return;
    setState(() {
      _testing = true;
      _found = null;
    });
    try {
      final tools = await _tools.toolsOf(c, refresh: true);
      if (mounted) setState(() => _found = tools);
    } catch (e) {
      _snackbar.showSnackbar('$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _delete() async {
    final s = widget.server;
    if (s == null) return;
    final ok = await showConfirm(
      context,
      title: tr('删除 MCP 服务器'),
      message: trArgs('「{0}」将被删除。', [s.name]),
      confirmText: tr('删除'),
      destructive: true,
    );
    if (!ok) return;
    await _tools.deleteServer(s.id);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final found = _found;
    return SettingsScaffold(
      title: widget.server == null ? tr('添加 MCP 服务器') : tr('MCP 服务器'),
      snackbar: _snackbar,
      actions: [
        if (widget.server != null)
          AppIconButton(icon: AppIcons.delete, onPressed: _delete),
      ],
      bottomBar: PrimaryButton(
        text: tr('保存'),
        onPressed: () async {
          if (await _save() != null && context.mounted) {
            Navigator.of(context).maybePop();
          }
        },
      ),
      children: [
        SettingsGroup(
          children: [
            SettingsField(
              controller: _name,
              label: tr('名称（可选）'),
              autocorrect: true,
            ),
            SettingsField(
              controller: _url,
              label: tr('网址'),
              hint: tr('如 https://example.com/mcp'),
              keyboardType: TextInputType.url,
            ),
            SettingsField(
              controller: _token,
              label: tr('访问令牌（可选）'),
              hint: tr('以 Bearer 方式发送，存在系统钥匙串里'),
              obscure: true,
            ),
            MiuixSwitchPreference(
              title: tr('启用'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ],
        ),
        SettingsGroup(
          children: [
            MiuixArrowPreference(
              title: _testing ? tr('正在连接…') : tr('测试连接'),
              summary: found == null
                  ? tr('保存并列出服务器提供的工具')
                  : trArgs('找到 {0} 个工具', [found.length]),
              enabled: !_testing,
              onClick: _test,
            ),
          ],
        ),
        if (found != null && found.isNotEmpty)
          SettingsGroup(
            title: tr('工具'),
            children: [
              for (final t in found)
                MiuixBasicComponent(
                  title: t.name,
                  summary: t.description.isEmpty ? null : t.description,
                ),
            ],
          ),
        if (found != null && found.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 0),
            child: MiuixText(
              tr('服务器没有提供任何工具'),
              fontSize: 12,
              color: colors.onSurfaceVariantSummary,
            ),
          ),
      ],
    );
  }
}
