import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io';

import '../../data/config_transfer.dart';
import '../../data/sync/sync_service.dart';
import '../conversations/conversation_list.dart' show formatRelativeTime;
import '../../data/providers.dart';
import '../../ui/dialogs.dart';
import '../../ui/settings_widgets.dart';

class DataPage extends ConsumerStatefulWidget {
  const DataPage({super.key});

  @override
  ConsumerState<DataPage> createState() => _DataPageState();
}

class _DataPageState extends ConsumerState<DataPage> {
  final _snackbar = MiuixSnackbarHostState();

  ConfigTransfer get _transfer =>
      ConfigTransfer(ref.read(databaseProvider), ref.read(keyStoreProvider));

  @override
  void dispose() {
    _snackbar.dispose();
    super.dispose();
  }

  Future<void> _export(bool withKeys) async {
    if (withKeys &&
        !await showConfirm(
          context,
          title: '包含 API Key？',
          message: 'API Key 会以明文复制到剪贴板，请只粘贴到你信任的地方，用完及时清除。',
          confirmText: '继续',
        )) {
      return;
    }
    final json = await _transfer.export(includeKeys: withKeys);
    await Clipboard.setData(ClipboardData(text: json));
    _snackbar.showSnackbar('配置已复制到剪贴板');
  }

  Future<void> _import() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (text.trim().isEmpty) {
      _snackbar.showSnackbar('剪贴板是空的');
      return;
    }
    try {
      _snackbar.showSnackbar(await _transfer.import(text));
    } on FormatException catch (e) {
      _snackbar.showSnackbar(e.message);
    }
  }

  Future<void> _clear() async {
    final ok = await showConfirm(
      context,
      title: '清空所有对话',
      message: ref.read(syncServiceProvider).enabled
          ? '所有对话和消息将被永久删除。已开启 iCloud 同步，其它设备上的对话也会一起删除。渠道和模型配置不受影响。'
          : '所有对话和消息将被永久删除，渠道和模型配置不受影响。',
      confirmText: '清空',
      destructive: true,
    );
    if (!ok) return;
    await _transfer.clearChats();
    ref.read(selectedConversationProvider.notifier).select(null);
    _snackbar.showSnackbar('已清空');
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return SettingsScaffold(
      title: '数据',
      snackbar: _snackbar,
      children: [
        if (SyncService.supported) _SyncGroup(snackbar: _snackbar),
        SettingsGroup(
          title: '配置迁移（渠道、模型、助手）',
          children: [
            MiuixArrowPreference(
              title: '导出到剪贴板',
              summary: '不含 API Key',
              onClick: () => _export(false),
            ),
            MiuixArrowPreference(
              title: '导出到剪贴板（含 API Key）',
              summary: '用于迁移到另一台设备',
              onClick: () => _export(true),
            ),
            MiuixArrowPreference(
              title: '从剪贴板导入',
              summary: '同 ID 的配置会被覆盖',
              onClick: _import,
            ),
          ],
        ),
        SettingsGroup(
          children: [
            MiuixBasicComponent(
              title: '清空所有对话',
              titleColor: MiuixBasicComponentColors(
                color: colors.error,
                disabledColor: colors.disabledOnSurface,
              ),
              onClick: _clear,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
          child: MiuixText(
            '数据默认只保存在本机：对话在本地数据库，API Key 在系统钥匙串。'
            '打开 iCloud 同步后，对话和配置会存进你自己的 iCloud 云盘（App 专用目录），'
            '在登录同一 Apple 账户的 iPhone、iPad、Mac 之间同步；API Key 只有打开「同步 API Key」'
            '才会通过 iCloud 钥匙串同步。除此之外不会上传到任何服务器（除了你配置的模型接口）。',
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
        ),
      ],
    );
  }
}

class _SyncGroup extends ConsumerWidget {
  const _SyncGroup({required this.snackbar});

  final MiuixSnackbarHostState snackbar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncServiceProvider);
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final colors = MiuixTheme.of(context).colors;
        final last = sync.lastSync;
        final status = sync.syncing
            ? '正在同步…'
            : sync.lastError ??
                  (last == null
                      ? '尚未同步'
                      : '上次同步：${formatRelativeTime(last)}'
                            '${sync.lastReport == null ? '' : '，${sync.lastReport}'}');
        return SettingsGroup(
          title: 'iCloud 同步',
          children: [
            MiuixSwitchPreference(
              title: '通过 iCloud 同步',
              summary: '对话、文件夹、渠道、模型、助手和提示词在苹果设备间同步',
              value: sync.enabled,
              onChanged: (on) async {
                final error = await sync.setEnabled(on);
                if (error != null) snackbar.showSnackbar(error);
              },
            ),
            if (sync.enabled) ...[
              MiuixArrowPreference(
                title: '立即同步',
                summary: status,
                summaryColor: sync.lastError != null && !sync.syncing
                    ? MiuixBasicComponentColors(
                        color: colors.error,
                        disabledColor: colors.disabledOnSurface,
                      )
                    : null,
                enabled: !sync.syncing,
                onClick: sync.syncNow,
              ),
              if (Platform.isIOS)
                MiuixSwitchPreference(
                  title: '同步 API Key',
                  summary: '通过 iCloud 钥匙串（端到端加密），其它设备不用重新填 Key',
                  value: sync.syncKeys,
                  onChanged: sync.setSyncKeys,
                ),
            ],
          ],
        );
      },
    );
  }
}
