import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/chat/chat_types.dart';
import '../../core/chat/participant.dart';
import '../../data/chat_service.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/motion.dart';
import '../../ui/top_bar_text.dart';
import 'message_views.dart';
import '../../l10n/tr.dart';

/// 导出的对话内容：哪些消息、每条回答的标签。
class ExportItem {
  const ExportItem(this.message, this.label);
  final Message message;

  /// 助手回答的标签（模型 / 助手名，裁判、辩论轮次等）；用户消息为 null。
  final String? label;
}

/// 按对话顺序整理要导出的消息。[onlyMessageId] 不为空时只导出那一条回答
/// （连同它回答的那个问题）。
List<ExportItem> exportItems(
  List<Message> messages,
  String Function(Message) labelOf, {
  String? onlyMessageId,
}) {
  var list = messages.where((m) => m.role != 'system').toList();
  if (onlyMessageId != null) {
    final idx = list.indexWhere((m) => m.id == onlyMessageId);
    if (idx < 0) return const [];
    final question = list
        .sublist(0, idx)
        .lastWhere((m) => m.role == 'user', orElse: () => list[idx]);
    list = [if (question.id != onlyMessageId) question, list[idx]];
  }
  return [
    for (final m in list)
      if (m.role == 'user' ||
          ContentPart.decodeList(m.partsJson).text.isNotEmpty)
        ExportItem(m, m.role == 'user' ? null : labelOf(m)),
  ];
}

/// 回答的标签：参与者名 + 裁判 / 辩论 / 接力步骤 / 已采纳等标记。
String exportLabel(
  Message m,
  List<Message> all,
  String Function(Participant) name,
) {
  final n = name(Participant(modelId: m.modelId ?? '', agentId: m.agentId));
  if (m.kind == MsgKind.judge) return trArgs('裁判 · {0}', [n]);
  if (m.kind == MsgKind.summary) return trArgs('辩论总结 · {0}', [n]);
  final siblings = m.groupId == null
      ? const <Message>[]
      : all.where((x) => x.groupId == m.groupId).toList();
  if (m.kind == MsgKind.debate) {
    final key = '${m.modelId}|${m.agentId}';
    final round =
        siblings
            .where(
              (s) =>
                  s.kind == MsgKind.debate &&
                  '${s.modelId}|${s.agentId}' == key &&
                  (s.stepIndex ?? 0) < (m.stepIndex ?? 0),
            )
            .length +
        1;
    return trArgs('辩论 · {0} · 第 {1} 轮', [n, round]);
  }
  if (m.stepIndex != null) {
    return trArgs('接力第 {0} 步 · {1}', [m.stepIndex! + 1, n]);
  }
  if (siblings.length > 1) return m.adopted ? trArgs('{0}（已采纳）', [n]) : n;
  return n;
}

/// 导出为 Markdown。
String conversationMarkdown(String title, List<ExportItem> items) {
  final b = StringBuffer('# $title\n\n');
  for (final it in items) {
    final parts = ContentPart.decodeList(it.message.partsJson);
    if (it.label == null) {
      b.write(tr('## 我\n\n'));
      if (parts.quote case final q?) {
        b.write('${q.split('\n').map((l) => '> $l').join('\n')}\n\n');
      }
      for (final f in parts.files) {
        b.write('📎 ${f.name}\n\n');
      }
      if (parts.images.isNotEmpty) {
        b.write(trArgs('（{0} 张图片）\n\n', [parts.images.length]));
      }
      if (parts.text.isNotEmpty) b.write('${parts.text}\n\n');
    } else {
      b.write('## ${it.label}\n\n${parts.text.trim()}\n\n');
      final cites = parts.citations;
      if (cites.isNotEmpty) {
        b.write(tr('来源：\n'));
        for (final (i, c) in cites.indexed) {
          b.write('${i + 1}. [${c.title ?? c.url}](${c.url})\n');
        }
        b.write('\n');
      }
    }
  }
  return b.toString().trimRight();
}

/// 文件名里不能出现的字符替换掉。
String safeFileName(String s) {
  final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ').trim();
  return t.isEmpty ? tr('对话') : (t.length > 40 ? t.substring(0, 40) : t);
}

/// 分享文件（系统分享面板）。iPad 上需要给出弹出位置。
Future<void> shareFile(BuildContext context, File file, {String? text}) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path)],
      text: text,
      sharePositionOrigin: box == null || !box.hasSize
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}

Future<File> writeTemp(String name, List<int> bytes) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes, flush: true);
  return f;
}

/// 长图预览：完整渲染对话（或单条回答），可保存到相册或分享。
class ExportImagePage extends ConsumerStatefulWidget {
  const ExportImagePage({
    super.key,
    required this.conversationId,
    this.onlyMessageId,
  });

  final String conversationId;
  final String? onlyMessageId;

  @override
  ConsumerState<ExportImagePage> createState() => _ExportImagePageState();
}

class _ExportImagePageState extends ConsumerState<ExportImagePage> {
  final _boundary = GlobalKey();
  bool _busy = false;

  /// 渲染成 PNG。超长时降低倍率，避免超过显卡纹理上限。
  Future<Uint8List?> _capture() async {
    final box =
        _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (box == null) return null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final ratio = math.min(
      math.min(dpr, 3.0),
      14000 / math.max(box.size.height, box.size.width),
    );
    final image = await box.toImage(pixelRatio: ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  }

  Future<void> _run(Future<void> Function(Uint8List png) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final png = await _capture();
      if (png != null) await action(png);
    } catch (e) {
      if (mounted) _toast(trArgs('操作失败：{0}', [e]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  final _snackbar = MiuixSnackbarHostState();
  void _toast(String m) => _snackbar.showSnackbar(m);

  @override
  void dispose() {
    _snackbar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final conv = ref.watch(conversationProvider(widget.conversationId));
    final messages =
        ref.watch(messagesProvider(widget.conversationId)).value ?? const [];
    final models = ref.watch(modelsProvider).value ?? const [];
    final agents = ref.watch(agentsProvider).value ?? const [];
    final items = exportItems(
      messages,
      (m) =>
          exportLabel(m, messages, (p) => participantLabel(p, models, agents)),
      onlyMessageId: widget.onlyMessageId,
    );
    final title = conv == null
        ? tr('对话')
        : ChatService.displayTitle(conv.title);

    return MiuixScaffold(
      snackbarHost: MiuixSnackbarHost(state: _snackbar),
      topBar: TopBarTextFix(
        child: MiuixSmallTopAppBar(
          title: tr('生成图片'),
          navigationIcon: AppIconButton(
            icon: AppIcons.back,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          actions: [
            AppIconButton(
              icon: AppIcons.download,
              onPressed: () => _run((png) async {
                if (!await Gal.hasAccess(toAlbum: false)) {
                  await Gal.requestAccess();
                }
                await Gal.putImageBytes(png, name: safeFileName(title));
                _toast(tr('已保存到相册'));
              }),
            ),
            Builder(
              builder: (btnContext) => AppIconButton(
                icon: AppIcons.share,
                onPressed: () => _run((png) async {
                  final f = await writeTemp('${safeFileName(title)}.png', png);
                  if (btnContext.mounted) await shareFile(btnContext, f);
                }),
              ),
            ),
          ],
        ),
      ),
      content: (padding) => Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: EdgeInsets.only(
                top: padding.top + 8,
                bottom: padding.bottom + 24,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: RepaintBoundary(
                    key: _boundary,
                    child: _ExportCanvas(title: title, items: items),
                  ),
                ),
              ),
            ),
            if (_busy)
              Positioned.fill(
                child: ColoredBox(
                  color: colors.surface.withValues(alpha: 0.4),
                  child: const Center(child: MiuixInfiniteProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 图片里的内容：标题、每条消息、底部水印。背景不透明，保存后不会是透明底。
class _ExportCanvas extends StatelessWidget {
  const _ExportCanvas({required this.title, required this.items});

  final String title;
  final List<ExportItem> items;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return ColoredBox(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MiuixText(title, fontSize: 20, fontWeight: FontWeight.w600),
            const SizedBox(height: 16),
            for (final it in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: it.label == null
                    ? UserBubble(message: it.message)
                    : Container(
                        padding: const EdgeInsets.all(14),
                        decoration: ShapeDecoration(
                          color: colors.surfaceContainer,
                          shape: const MiuixSquircleBorder(cornerRadius: 16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            MiuixText(
                              it.label!,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colors.primary,
                            ),
                            const SizedBox(height: 6),
                            AssistantMessage(
                              message: it.message,
                              showHeader: false,
                              showActions: false,
                            ),
                          ],
                        ),
                      ),
              ),
            Center(
              child: MiuixText(
                tr('由 XCAgent 生成'),
                fontSize: 11,
                color: colors.onSurfaceVariantSummary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 导出整段对话：Markdown 文件 / 复制 Markdown / 长图。
Future<void> showExportSheet(
  BuildContext context,
  WidgetRef ref, {
  required String conversationId,
  String? onlyMessageId,
  required void Function(String) toast,
}) async {
  final conv = ref.read(conversationProvider(conversationId));
  final messages = await ref
      .read(chatServiceProvider)
      .messagesOf(conversationId);
  final models = ref.read(modelsProvider).value ?? const [];
  final agents = ref.read(agentsProvider).value ?? const [];
  final items = exportItems(
    messages,
    (m) => exportLabel(m, messages, (p) => participantLabel(p, models, agents)),
    onlyMessageId: onlyMessageId,
  );
  final title = conv?.title ?? tr('对话');
  final md = conversationMarkdown(title, items);
  if (!context.mounted) return;
  await showActionSheet(
    context,
    title: onlyMessageId == null ? tr('导出对话') : tr('分享回答'),
    actions: [
      SheetAction(tr('生成图片'), () {
        Navigator.of(context).push(
          appRoute(
            ExportImagePage(
              conversationId: conversationId,
              onlyMessageId: onlyMessageId,
            ),
          ),
        );
      }, icon: AppIcons.image),
      SheetAction(tr('分享 Markdown 文件'), () async {
        final f = await writeTemp('${safeFileName(title)}.md', utf8.encode(md));
        if (context.mounted) await shareFile(context, f);
      }, icon: AppIcons.share),
      SheetAction(tr('复制为 Markdown'), () {
        Clipboard.setData(ClipboardData(text: md));
        toast(tr('已复制'));
      }, icon: AppIcons.copy),
    ],
  );
}
