import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/settings_widgets.dart';
import '../../ui/vendor/app_text_field.dart';
import '../../l10n/tr.dart';

final promptsProvider = StreamProvider<List<Prompt>>(
  (ref) => ref.watch(databaseProvider).watchPrompts(),
);

/// 提示词库：在输入框里打 / 调出。
class PromptsPage extends ConsumerWidget {
  const PromptsPage({super.key});

  void _edit(BuildContext context, [Prompt? p]) =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => PromptEditPage(prompt: p)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final prompts = ref.watch(promptsProvider).value ?? const [];
    return SettingsScaffold(
      title: tr('提示词'),
      actions: [
        AppIconButton(icon: AppIcons.add, onPressed: () => _edit(context)),
      ],
      children: [
        if (prompts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 32),
            child: Column(
              children: [
                MiuixText(
                  tr('常用的提问方式存成提示词，\n聊天时在输入框里打 / 就能调出'),
                  textAlign: TextAlign.center,
                  color: colors.onSurfaceVariantSummary,
                ),
                const SizedBox(height: 24),
                PrimaryButton(
                  text: tr('新建提示词'),
                  onPressed: () => _edit(context),
                ),
              ],
            ),
          )
        else
          SettingsGroup(
            title: tr('在输入框里打 / 调出'),
            children: [
              for (final p in prompts)
                MiuixArrowPreference(
                  title: p.title,
                  summary: p.content.trim().replaceAll('\n', ' '),
                  onClick: () => _edit(context, p),
                ),
            ],
          ),
      ],
    );
  }
}

class PromptEditPage extends ConsumerStatefulWidget {
  const PromptEditPage({super.key, this.prompt});

  final Prompt? prompt;

  @override
  ConsumerState<PromptEditPage> createState() => _PromptEditPageState();
}

class _PromptEditPageState extends ConsumerState<PromptEditPage> {
  late final _title = TextEditingController(text: widget.prompt?.title);
  late final _content = TextEditingController(text: widget.prompt?.content);
  final _snackbar = MiuixSnackbarHostState();

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _snackbar.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty || _content.text.trim().isEmpty) {
      _snackbar.showSnackbar(tr('名称和内容都要填写'));
      return;
    }
    final db = ref.read(databaseProvider);
    final existing = widget.prompt;
    final count = (await db.select(db.prompts).get()).length;
    await db
        .into(db.prompts)
        .insertOnConflictUpdate(
          PromptsCompanion(
            id: Value(existing?.id ?? newId()),
            title: Value(title),
            content: Value(_content.text),
            sortOrder: Value(existing?.sortOrder ?? count),
          ),
        );
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _delete() async {
    final p = widget.prompt;
    if (p == null) return;
    final ok = await showConfirm(
      context,
      title: tr('删除提示词'),
      message: trArgs('「{0}」将被删除。', [p.title]),
      confirmText: tr('删除'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    final db = ref.read(databaseProvider);
    await (db.delete(db.prompts)..where((x) => x.id.equals(p.id))).go();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: widget.prompt == null ? tr('新建提示词') : tr('编辑提示词'),
      snackbar: _snackbar,
      actions: [
        if (widget.prompt != null)
          AppIconButton(icon: AppIcons.delete, onPressed: _delete),
      ],
      bottomBar: PrimaryButton(text: tr('保存'), onPressed: _save),
      children: [
        SettingsGroup(
          children: [
            SettingsField(
              controller: _title,
              label: tr('名称'),
              autocorrect: true,
            ),
          ],
        ),
        SettingsGroup(
          title: tr('内容（选用后填进输入框，可以接着补充）'),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: AppTextField(
                controller: _content,
                label: tr('例如：把下面的内容翻译成英文：'),
                useLabelAsPlaceholder: true,
                minLines: 4,
                maxLines: 14,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
