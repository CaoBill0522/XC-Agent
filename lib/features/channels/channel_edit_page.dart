import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/motion.dart';
import '../../core/api/api_error.dart';
import '../../core/api/endpoint.dart';
import '../../core/api/protocol.dart';
import '../../core/providers/provider_preset.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/settings_widgets.dart';
import 'model_picker_page.dart';

/// 新建（传 [preset]）或编辑（传 [channelId]）渠道。
class ChannelEditPage extends ConsumerStatefulWidget {
  const ChannelEditPage({super.key, this.preset, this.channelId})
    : assert((preset == null) != (channelId == null));

  final ProviderPreset? preset;
  final String? channelId;

  @override
  ConsumerState<ChannelEditPage> createState() => _ChannelEditPageState();
}

class _TestResult {
  const _TestResult(this.ok, this.message, [this.detail]);

  final bool ok;
  final String message;
  final String? detail;
}

class _ChannelEditPageState extends ConsumerState<ChannelEditPage> {
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _snackbar = MiuixSnackbarHostState();

  ProviderPreset? _preset;
  Channel? _channel;
  ApiProtocol _protocol = ApiProtocol.openaiChat;
  bool _obscureKey = true;
  bool _busy = false;
  bool _confirmDelete = false;
  _TestResult? _testResult;

  bool get _isNew => widget.channelId == null;

  @override
  void initState() {
    super.initState();
    if (widget.preset case final p?) {
      _applyPreset(p);
    } else {
      _loadExisting();
    }
  }

  void _applyPreset(ProviderPreset p) {
    _preset = p;
    _protocol = p.defaultEndpoint.protocol;
    _baseUrl.text = p.defaultEndpoint.baseUrl;
    _name.text = p.isCustom ? '' : p.name;
  }

  Future<void> _loadExisting() async {
    final repo = ref.read(channelRepositoryProvider);
    final channel = await repo.getChannel(widget.channelId!);
    if (channel == null || !mounted) return;
    final presets = await ref.read(presetsProvider.future);
    final key = await repo.readApiKey(channel.id) ?? '';
    if (!mounted) return;
    setState(() {
      _channel = channel;
      _preset =
          presets.where((p) => p.id == channel.presetId).firstOrNull ??
          presets.firstWhere((p) => p.isCustom);
      _protocol = ApiProtocol.fromId(channel.protocol);
      _name.text = channel.name;
      _baseUrl.text = channel.baseUrl;
      _apiKey.text = key;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _snackbar.dispose();
    super.dispose();
  }

  List<ApiProtocol> get _protocols =>
      _preset?.endpoints.map((e) => e.protocol).toList() ?? ApiProtocol.values;

  void _changeProtocol(ApiProtocol p) {
    setState(() {
      _protocol = p;
      _testResult = null;
      // 预设厂商切换协议时，地址跟着换（不同协议地址不同，如智谱）。
      final preset = _preset;
      if (preset != null && !preset.isCustom) {
        _baseUrl.text = preset.endpointFor(p)?.baseUrl ?? _baseUrl.text;
      }
    });
  }

  ChannelEndpoint get _endpoint => ChannelEndpoint(
    protocol: _protocol,
    baseUrl: _baseUrl.text,
    apiKey: _apiKey.text.trim(),
  );

  String? _validate() {
    if (_baseUrl.text.trim().isEmpty) return '请填写 Base URL';
    if (Uri.tryParse(_endpoint.baseUrl)?.host.isEmpty ?? true) {
      return 'Base URL 格式不正确';
    }
    if (_apiKey.text.trim().isEmpty) return '请填写 API Key';
    return null;
  }

  Future<void> _test() async {
    if (_validate() case final err?) {
      setState(() => _testResult = _TestResult(false, err));
      return;
    }
    setState(() {
      _busy = true;
      _testResult = null;
    });
    final client = ref.read(channelClientProvider);
    final endpoint = _endpoint;
    _TestResult result;
    final sw = Stopwatch()..start();
    try {
      final models = await client.listModels(endpoint);
      result = _TestResult(
        true,
        '连接正常 · ${sw.elapsedMilliseconds} ms · 发现 ${models.length} 个模型',
      );
    } on ApiException catch (e) {
      // 没有 /models 接口（如智谱）：改用一个已知模型发最小对话请求。
      final model = e.isNotFound ? await _pickTestModel() : null;
      if (model == null) {
        result = _TestResult(
          false,
          e.isNotFound ? '${e.message}（该渠道可能不提供模型列表，可保存后手动添加模型）' : e.message,
          e.detail,
        );
      } else {
        try {
          final r = await client.testChat(endpoint, model);
          result = _TestResult(
            true,
            '${r.message} · ${r.latency.inMilliseconds} ms · 测试模型 $model',
          );
        } on ApiException catch (e2) {
          result = _TestResult(false, '${e2.message}（测试模型 $model）', e2.detail);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _testResult = result;
    });
  }

  Future<String?> _pickTestModel() async {
    if (_channel case final c?) {
      final names = await ref
          .read(channelRepositoryProvider)
          .channelModelNames(c.id);
      if (names.isNotEmpty) return names.first;
    }
    final fallback = _preset?.fallbackModels ?? const [];
    return fallback.isEmpty ? null : fallback.first;
  }

  Future<void> _save() async {
    if (_validate() case final err?) {
      _snackbar.showSnackbar(err);
      return;
    }
    setState(() => _busy = true);
    final preset = _preset!;
    final id = await ref
        .read(channelRepositoryProvider)
        .saveChannel(
          id: widget.channelId,
          name: _name.text.trim().isEmpty ? preset.name : _name.text,
          presetId: preset.id,
          protocol: _protocol,
          baseUrl: _baseUrl.text,
          apiKey: _apiKey.text,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (_isNew) {
      // 新渠道保存后直接去选模型。
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ModelPickerPage(channelId: id, isFirstSetup: true),
        ),
      );
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _delete() async {
    setState(() => _confirmDelete = false);
    await ref.read(channelRepositoryProvider).deleteChannel(widget.channelId!);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final preset = _preset;
    if (preset == null) {
      return const SettingsScaffold(title: '编辑渠道', children: []);
    }

    final summary = ref
        .watch(channelsProvider)
        .value
        ?.where((s) => s.channel.id == widget.channelId)
        .firstOrNull;

    String requestUrlHint() {
      final e = _endpoint;
      return e.baseUrl.isEmpty
          ? '例如 https://api.example.com/v1'
          : '请求地址：${e.chatUrl}';
    }

    return SettingsScaffold(
      title: _isNew ? '添加 ${preset.name}' : '编辑渠道',
      snackbar: _snackbar,
      overlays: [
        if (!_isNew)
          ConfirmDialog(
            show: _confirmDelete,
            title: '删除渠道',
            message: '「${_name.text}」及其模型路由会被删除，API Key 也会从系统钥匙串移除。',
            confirmText: '删除',
            destructive: true,
            onConfirm: _delete,
            onCancel: () => setState(() => _confirmDelete = false),
          ),
      ],
      bottomBar: PrimaryButton(
        text: _isNew ? '保存并选择模型' : '保存',
        loading: _busy,
        onPressed: _save,
      ),
      children: [
        SettingsGroup(
          title: '接入',
          children: [
            SettingsField(
              controller: _name,
              label: '名称',
              hint: '留空则使用「${preset.name}」',
              autocorrect: true,
            ),
            if (_protocols.length > 1)
              MiuixOverlayDropdownPreference(
                title: '接口协议',
                items: [for (final p in _protocols) p.label],
                selectedIndex: _protocols
                    .indexOf(_protocol)
                    .clamp(0, _protocols.length - 1),
                onSelectedIndexChange: (i) => _changeProtocol(_protocols[i]),
              )
            else
              MiuixBasicComponent(title: '接口协议', summary: _protocol.label),
            SettingsField(
              controller: _baseUrl,
              label: 'Base URL',
              hint: requestUrlHint(),
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() => _testResult = null),
            ),
            SettingsField(
              controller: _apiKey,
              label: 'API Key',
              obscure: _obscureKey,
              hint: 'Key 保存在系统钥匙串中，不会写入数据库',
              onChanged: (_) => setState(() => _testResult = null),
              trailing: Tap(
                onTap: () => setState(() => _obscureKey = !_obscureKey),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: MiuixIcon(
                    vector: _obscureKey ? AppIcons.show : AppIcons.hide,
                    size: 22,
                    tint: colors.onSurfaceVariantActions,
                  ),
                ),
              ),
            ),
          ],
        ),
        SettingsGroup(
          children: [
            MiuixArrowPreference(
              title: '测试连接',
              summary: _busy ? '测试中…' : '检查地址和 Key 是否可用',
              enabled: !_busy,
              onClick: _test,
            ),
            if (_testResult case final r?)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MiuixText(
                      '${r.ok ? '✓' : '✗'} ${r.message}',
                      color: r.ok ? colors.primary : colors.error,
                      fontSize: 14,
                    ),
                    if (r.detail case final d?)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: SelectableText(
                          d,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariantSummary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
        if (!_isNew && _channel != null) ...[
          SettingsGroup(
            title: '模型',
            children: [
              MiuixArrowPreference(
                title: '管理模型',
                summary: '已启用 ${summary?.modelCount ?? 0} 个，可从云端重新拉取',
                onClick: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ModelPickerPage(channelId: _channel!.id),
                  ),
                ),
              ),
              MiuixSwitchPreference(
                title: '启用渠道',
                summary: '停用后，轮询时跳过该渠道',
                value: summary?.channel.enabled ?? _channel!.enabled,
                onChanged: (v) => ref
                    .read(channelRepositoryProvider)
                    .setChannelEnabled(_channel!.id, v),
              ),
            ],
          ),
          SettingsGroup(
            children: [
              MiuixBasicComponent(
                title: '删除渠道',
                titleColor: MiuixBasicComponentColors(
                  color: colors.error,
                  disabledColor: colors.disabledOnSurface,
                ),
                onClick: () => setState(() => _confirmDelete = true),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
