import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/motion.dart';
import '../../core/api/api_error.dart';
import '../../core/api/channel_client.dart';
import '../../core/models/capabilities.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/settings_widgets.dart';
import '../../ui/vendor/app_text_field.dart';

/// 从云端拉取渠道的模型列表并勾选启用。
class ModelPickerPage extends ConsumerStatefulWidget {
  const ModelPickerPage({
    super.key,
    required this.channelId,
    this.isFirstSetup = false,
  });

  final String channelId;

  /// 刚建好渠道：模型不多时按类型自动预选。
  final bool isFirstSetup;

  @override
  ConsumerState<ModelPickerPage> createState() => _ModelPickerPageState();
}

class _ModelPickerPageState extends ConsumerState<ModelPickerPage> {
  final _search = TextEditingController();
  final _manual = TextEditingController();
  final _snackbar = MiuixSnackbarHostState();

  bool _loading = true;
  bool _saving = false;
  ApiException? _error;
  bool _usingFallback = false;

  /// 列表中的全部模型 ID（云端 + 已启用 + 内置 + 手动添加），保持插入顺序。
  final _ids = <String>{};
  final _displayNames = <String, String>{};
  final _selected = <String>{};
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _fetch();
  }

  @override
  void dispose() {
    _search.dispose();
    _manual.dispose();
    _snackbar.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
      _usingFallback = false;
    });
    final repo = ref.read(channelRepositoryProvider);
    final channel = await repo.getChannel(widget.channelId);
    if (channel == null) return;
    final existing = await repo.channelModelNames(channel.id);
    final presets = await ref.read(presetsProvider.future);
    final fallback =
        presets
            .where((p) => p.id == channel.presetId)
            .firstOrNull
            ?.fallbackModels ??
        const [];

    List<RemoteModel> remote = const [];
    ApiException? error;
    try {
      remote = await ref
          .read(channelClientProvider)
          .listModels(await repo.endpointFor(channel));
    } on ApiException catch (e) {
      error = e;
    }
    if (!mounted) return;

    setState(() {
      _loading = false;
      _error = error;
      for (final m in remote) {
        _ids.add(m.id);
        if (m.displayName != null) _displayNames[m.id] = m.displayName!;
      }
      if (remote.isEmpty && fallback.isNotEmpty) {
        _usingFallback = true;
        _ids.addAll(fallback);
      }
      _ids.addAll(existing);

      if (!_initialized) {
        _initialized = true;
        if (existing.isNotEmpty) {
          _selected.addAll(existing);
        } else if (widget.isFirstSetup && _ids.length <= 30) {
          _selected.addAll(
            _ids.where((id) => inferModelProfile(id).selectedByDefault),
          );
        }
      }
    });
  }

  List<String> get _visible {
    final q = _search.text.trim().toLowerCase();
    final list = q.isEmpty
        ? _ids.toList()
        : _ids.where((id) => id.toLowerCase().contains(q)).toList();
    return list;
  }

  void _addManual() {
    final id = _manual.text.trim();
    if (id.isEmpty) return;
    setState(() {
      _ids.add(id);
      _selected.add(id);
      _manual.clear();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ref
        .read(channelRepositoryProvider)
        .syncChannelModels(widget.channelId, _selected);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final visible = _visible;
    final visibleChat = visible
        .where((id) => inferModelProfile(id).selectedByDefault)
        .toList();

    return SettingsScaffold(
      title: '选择模型',
      snackbar: _snackbar,
      actions: [
        AppIconButton(
          icon: AppIcons.refresh,
          enabled: !_loading,
          onPressed: _fetch,
        ),
      ],
      bottomBar: PrimaryButton(
        text: '保存（已选 ${_selected.length} 个）',
        loading: _saving,
        onPressed: _save,
      ),
      children: [
        if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: MiuixText(
                '正在从云端拉取模型…',
                color: colors.onSurfaceVariantSummary,
              ),
            ),
          ),
        if (_error case final e?)
          SettingsGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MiuixText('拉取失败：${e.message}', color: colors.error),
                    if (e.detail case final d?)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: MiuixText(
                          d,
                          fontSize: 12,
                          color: colors.onSurfaceVariantSummary,
                        ),
                      ),
                    const SizedBox(height: 6),
                    MiuixText(
                      _usingFallback
                          ? '已显示内置模型列表，也可以在下方手动添加。'
                          : '可以在下方手动添加模型 ID。',
                      fontSize: 13,
                      color: colors.onSurfaceVariantSummary,
                    ),
                  ],
                ),
              ),
            ],
          ),
        if (!_loading && _ids.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: AppTextField(
              controller: _search,
              label: '搜索模型',
              useLabelAsPlaceholder: true,
              singleLine: true,
              autocorrect: false,
              enableSuggestions: false,
              leadingIcon: Padding(
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: MiuixIcon(
                  vector: AppIcons.search,
                  size: 20,
                  tint: colors.onSurfaceVariantActions,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: MiuixText(
                    '共 ${visible.length} 个',
                    fontSize: 13,
                    color: colors.onSurfaceVariantSummary,
                  ),
                ),
                _LinkButton(
                  '选中对话模型',
                  onTap: () => setState(() => _selected.addAll(visibleChat)),
                ),
                const SizedBox(width: 16),
                _LinkButton(
                  '清空',
                  onTap: () => setState(() => _selected.removeAll(visible)),
                ),
              ],
            ),
          ),
          SettingsGroup(
            children: [
              for (final id in visible)
                _ModelRow(
                  id: id,
                  displayName: _displayNames[id],
                  selected: _selected.contains(id),
                  onToggle: () => setState(() {
                    if (!_selected.remove(id)) _selected.add(id);
                  }),
                ),
            ],
          ),
        ],
        if (!_loading)
          SettingsGroup(
            title: '手动添加',
            children: [
              SettingsField(
                controller: _manual,
                label: '模型 ID',
                hint: '列表里没有的模型，可以直接填写名称',
                trailing: Tap(
                  onTap: _addManual,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: MiuixIcon(
                      vector: AppIcons.add,
                      size: 22,
                      tint: colors.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.id,
    required this.displayName,
    required this.selected,
    required this.onToggle,
  });

  final String id;
  final String? displayName;
  final bool selected;
  final VoidCallback onToggle;

  // 图片模型已有「生图」能力标签，不再重复标注类型。
  static const _kindLabels = {
    ModelKind.embedding: '嵌入',
    ModelKind.audio: '语音',
    ModelKind.other: '其他',
  };

  @override
  Widget build(BuildContext context) {
    final profile = inferModelProfile(id);
    final kind = _kindLabels[profile.kind];
    return MiuixBasicComponent(
      title: id,
      summary: displayName != null && displayName != id ? displayName : null,
      bottomAction: profile.capabilities.isEmpty && kind == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: CapabilityBadges(profile.capabilities, extra: [?kind]),
            ),
      endActions: [
        MiuixCheckbox(value: selected, onChanged: (_) => onToggle()),
      ],
      onClick: onToggle,
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton(this.text, {required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: MiuixText(
        text,
        fontSize: 13,
        color: MiuixTheme.of(context).colors.primary,
      ),
    );
  }
}
