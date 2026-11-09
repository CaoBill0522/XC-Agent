import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../core/api/api_error.dart';
import '../../data/chat_service.dart';
import '../../data/image_store.dart';
import '../../data/providers.dart';
import '../../ui/app_icons.dart';
import '../../ui/dialogs.dart';
import '../../ui/image_view.dart';
import '../../ui/layout.dart';
import '../../ui/motion.dart';
import '../../ui/vendor/app_text_field.dart';
import '../../data/db/app_database.dart';
import '../settings/prompts_page.dart';
import 'follow_up.dart';

/// 输入栏的控制器：外部（拖拽、粘贴）也能往里加图片；追问时设置引用片段 /
/// 前文总结（显示在输入框上方，发送时一起带上）。
class InputBarController extends ChangeNotifier {
  final images = <PendingImage>[];

  /// 追问引用的回答片段。
  String? quote;

  /// 新对话追问时的前文总结（可能仍在生成中）。
  SummaryJob? summary;

  /// 请求输入框获取焦点（「追问」后直接开始输入）。
  final focusRequests = ValueNotifier<int>(0);

  void setQuote(String? text) {
    quote = text?.trim().isEmpty ?? true ? null : text!.trim();
    notifyListeners();
    if (quote != null) focusRequests.value++;
  }

  void setSummary(SummaryJob? job) {
    detachSummary()?.dispose();
    summary = job;
    job?.addListener(notifyListeners);
    notifyListeners();
  }

  /// 发送失败时把取走的内容放回（用户期间新加的内容保留在前面）。
  void restore({
    String? quote,
    List<PendingImage> images = const [],
    List<PendingFile> files = const [],
    SummaryJob? summary,
  }) {
    this.images.insertAll(0, images);
    this.files.insertAll(0, files);
    this.quote ??= quote;
    if (summary != null) {
      if (this.summary == null) {
        this.summary = summary..addListener(notifyListeners);
      } else {
        summary.dispose();
      }
    }
    notifyListeners();
  }

  /// 取下总结但不销毁（发送失败时还要放回去）。
  SummaryJob? detachSummary() {
    final job = summary;
    job?.removeListener(notifyListeners);
    summary = null;
    return job;
  }

  @override
  void dispose() {
    summary?.removeListener(notifyListeners);
    summary?.dispose();
    focusRequests.dispose();
    super.dispose();
  }

  Future<void> addImageBytes(Uint8List bytes) async {
    if (sniffImageMime(bytes) == null) return;
    final (data, mime) = await prepareImageForUpload(bytes);
    images.add(PendingImage(data, mime));
    notifyListeners();
  }

  void removeAt(int i) {
    images.removeAt(i);
    notifyListeners();
  }

  List<PendingImage> take() {
    final out = List<PendingImage>.of(images);
    images.clear();
    notifyListeners();
    return out;
  }

  /// 附件文件（PDF、文本、代码等）。
  final files = <PendingFile>[];

  /// 加入附件；不支持的类型或过大时返回错误提示，成功返回 null。
  String? addFile(Uint8List bytes, String name) {
    final kind = attachmentKind(name, bytes);
    if (kind == null) return '不支持「$name」这种文件（支持 PDF、文本和代码文件）';
    final limit = kind == AttachmentKind.pdf ? maxPdfBytes : maxTextFileBytes;
    if (bytes.length > limit) {
      return '「$name」太大了（上限 ${formatBytes(limit)}）';
    }
    files.add(
      PendingFile(
        bytes,
        name,
        kind == AttachmentKind.pdf ? 'application/pdf' : 'text/plain',
      ),
    );
    notifyListeners();
    return null;
  }

  void removeFile(int i) {
    files.removeAt(i);
    notifyListeners();
  }

  List<PendingFile> takeFiles() {
    final out = List<PendingFile>.of(files);
    files.clear();
    return out;
  }
}

class ChatInputBar extends ConsumerStatefulWidget {
  const ChatInputBar({
    super.key,
    required this.conversationId,
    required this.controller,
    required this.generating,
    required this.webSearchSupported,
    required this.hasParticipants,
    required this.onError,
  });

  final String conversationId;
  final InputBarController controller;
  final bool generating;
  final bool webSearchSupported;
  final bool hasParticipants;
  final ValueChanged<String> onError;

  @override
  ConsumerState<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends ConsumerState<ChatInputBar> {
  final _text = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
    widget.controller.focusRequests.addListener(_requestFocus);
    _text.addListener(_rebuild);
  }

  void _requestFocus() => _focus.requestFocus();

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    widget.controller.focusRequests.removeListener(_requestFocus);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() => setState(() {});

  /// 输入以 / 开头（还没换行）时，/ 后面的文字用来筛选提示词。
  String? get _slashQuery {
    final t = _text.text;
    if (!t.startsWith('/') || t.contains('\n')) return null;
    return t.substring(1);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;

    // 桌面端粘贴图片：剪贴板里是图片时拦截，否则交给输入框正常粘贴文字。
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (hw.isMetaPressed || hw.isControlPressed)) {
      _pasteImage();
      return KeyEventResult.ignored;
    }

    if (!isDesktopPlatform) return KeyEventResult.ignored;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter || hw.isShiftPressed) return KeyEventResult.ignored;
    if (_text.value.composing.isValid) return KeyEventResult.ignored;
    _send();
    return KeyEventResult.handled;
  }

  Future<void> _pasteImage() async {
    try {
      final bytes = await Pasteboard.image;
      if (bytes != null) await widget.controller.addImageBytes(bytes);
    } catch (_) {}
  }

  Future<void> _pick() async {
    final picker = ImagePicker();
    Future<void> fromGallery() async {
      final files = await picker.pickMultiImage(limit: 6);
      for (final f in files) {
        await widget.controller.addImageBytes(await f.readAsBytes());
      }
    }

    final mobile = Platform.isIOS || Platform.isAndroid;
    await showActionSheet(
      context,
      actions: [
        SheetAction(
          mobile ? '从相册选择' : '选择图片',
          fromGallery,
          icon: AppIcons.image,
        ),
        if (mobile)
          SheetAction('拍照', () async {
            final f = await picker.pickImage(source: ImageSource.camera);
            if (f != null) {
              await widget.controller.addImageBytes(await f.readAsBytes());
            }
          }, icon: AppIcons.photos),
        SheetAction('选择文件（PDF、文本、代码）', _pickFiles, icon: AppIcons.file),
      ],
    );
  }

  Future<void> _pickFiles() async {
    final files = await openFiles();
    for (final f in files) {
      final bytes = await f.readAsBytes();
      final isImage = sniffImageMime(bytes) != null;
      if (isImage) {
        await widget.controller.addImageBytes(bytes);
        continue;
      }
      final error = widget.controller.addFile(bytes, f.name);
      if (error != null) widget.onError(error);
    }
  }

  Future<void> _send() async {
    if (widget.generating) return;
    final c = widget.controller;
    final text = _text.text.trim();
    if (text.isEmpty &&
        c.images.isEmpty &&
        c.files.isEmpty &&
        c.quote == null) {
      return;
    }
    if (!widget.hasParticipants) {
      widget.onError('请先选择对话方式');
      return;
    }
    if (c.summary?.loading ?? false) {
      widget.onError('前文总结还在生成，请稍候');
      return;
    }
    final quote = c.quote;
    final job = c.detachSummary();
    final summary = job?.error == null ? job?.text : null;
    final images = c.take();
    final files = c.takeFiles();
    c.quote = null;
    _text.clear();
    // 手机上发送后收起键盘（与 ChatGPT 客户端一致），方便看回答；
    // 桌面端保留焦点，可以接着输入。
    if (!isDesktopPlatform) _focus.unfocus();
    try {
      await ref
          .read(chatServiceProvider)
          .send(
            widget.conversationId,
            text,
            images: images,
            files: files,
            quote: quote,
            context: summary,
          );
      job?.dispose();
    } on ApiException catch (e) {
      // 没发出去：把文字、图片、引用和总结都放回输入栏，不让用户重来。
      if (mounted) {
        if (_text.text.isEmpty) _text.text = text;
        c.restore(quote: quote, images: images, files: files, summary: job);
      } else {
        job?.dispose();
      }
      widget.onError(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final media = MediaQuery.of(context);
    final bottom = media.viewInsets.bottom > 0
        ? media.viewInsets.bottom
        : media.padding.bottom;
    final conv = ref.watch(conversationProvider(widget.conversationId));
    final webOn = conv?.webSearch ?? false;
    final images = widget.controller.images;
    final c = widget.controller;
    final canSend =
        (_text.text.trim().isNotEmpty ||
            images.isNotEmpty ||
            c.files.isNotEmpty ||
            c.quote != null) &&
        !(c.summary?.loading ?? false);

    // 输入框与按钮统一高度，单行时三者垂直居中对齐；多行时按钮贴底。
    const control = 44.0;
    // 无背景的图标按钮：图标比按钮小 20，左移半边让图标与消息左边缘对齐。
    const iconInset = (control - 24) / 2;

    return LayoutBuilder(
      builder: (context, box) {
        final gutter = chatGutter(context, box.maxWidth);
        return Padding(
          padding: EdgeInsets.fromLTRB(0, 6, 0, 8 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 打 / 调出提示词。
              AnimatedSize(
                duration: Motion.medium,
                curve: Motion.curve,
                alignment: Alignment.bottomLeft,
                child: _slashQuery == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
                        child: PromptPanel(
                          query: _slashQuery!,
                          onPick: (p) {
                            _text.value = TextEditingValue(
                              text: p.content,
                              selection: TextSelection.collapsed(
                                offset: p.content.length,
                              ),
                            );
                            _focus.requestFocus();
                          },
                        ),
                      ),
              ),
              // 追问：前文总结 + 引用片段，显示在输入框上方。
              AnimatedSize(
                duration: Motion.medium,
                curve: Motion.curve,
                alignment: Alignment.bottomLeft,
                child: c.quote == null && c.summary == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 8),
                        child: FollowUpAttachments(
                          quote: c.quote,
                          summary: c.summary,
                          onRemoveQuote: () => c.setQuote(null),
                          onRemoveSummary: () => c.setSummary(null),
                        ),
                      ),
              ),
              AnimatedSize(
                duration: Motion.medium,
                curve: Motion.curve,
                alignment: Alignment.bottomLeft,
                child: c.files.isEmpty
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: EdgeInsets.fromLTRB(gutter, 2, gutter, 6),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final (i, f) in c.files.indexed)
                              AppearIn(
                                key: ObjectKey(f),
                                child: FileChip(
                                  name: f.name,
                                  size: f.bytes.length,
                                  onRemove: () => c.removeFile(i),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
              AnimatedSize(
                duration: Motion.medium,
                curve: Motion.curve,
                alignment: Alignment.bottomLeft,
                child: images.isEmpty
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 8, top: 6),
                        child: SizedBox(
                          height: 64,
                          child: ListView.separated(
                            // 缩略图右上角的删除按钮会超出 6，留出空间。
                            padding: EdgeInsets.fromLTRB(gutter, 6, gutter, 0),
                            clipBehavior: Clip.none,
                            scrollDirection: Axis.horizontal,
                            itemCount: images.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
                            itemBuilder: (_, i) => AppearIn(
                              key: ObjectKey(images[i]),
                              child: MemoryThumb(
                                images[i].bytes,
                                size: 58,
                                onRemove: () => widget.controller.removeAt(i),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              Padding(
                padding: EdgeInsets.only(
                  left: gutter - iconInset,
                  right: gutter,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    AppIconButton(
                      icon: AppIcons.image,
                      extent: control,
                      tint: colors.onSurfaceVariantActions,
                      onPressed: _pick,
                    ),
                    AppIconButton(
                      icon: AppIcons.world,
                      extent: control,
                      tint: webOn && widget.webSearchSupported
                          ? colors.primary
                          : colors.onSurfaceVariantActions,
                      onPressed: () {
                        if (!widget.webSearchSupported) {
                          widget.onError('当前模型 / 渠道不支持原生联网搜索');
                          return;
                        }
                        ref
                            .read(chatServiceProvider)
                            .setWebSearch(widget.conversationId, !webOn);
                        widget.onError(webOn ? '已关闭联网搜索' : '已开启联网搜索');
                      },
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: AppTextField(
                        controller: _text,
                        focusNode: _focus,
                        label: c.quote != null || c.summary != null
                            ? '继续追问…'
                            : '输入消息',
                        useLabelAsPlaceholder: true,
                        minLines: 1,
                        maxLines: 6,
                        cornerRadius: control / 2,
                        // 16 号字 × 1.375 行高 = 22，上下各 10，再加输入框自身约 2 的排版余量，单行总高 44。
                        textStyle: TextStyle(
                          fontSize: 16,
                          height: 1.375,
                          color: colors.onSurface,
                        ),
                        insideMargin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        textInputAction: isDesktopPlatform
                            ? TextInputAction.newline
                            : TextInputAction.send,
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    PopSwitch(
                      switchKey: widget.generating,
                      child: widget.generating
                          ? AppIconButton(
                              icon: AppIcons.stop,
                              extent: control,
                              tint: colors.onPrimary,
                              backgroundColor: colors.primary,
                              onPressed: () => ref
                                  .read(chatServiceProvider)
                                  .stopConversation(widget.conversationId),
                            )
                          : TweenAnimationBuilder<Color?>(
                              tween: ColorTween(
                                end: canSend
                                    ? colors.primary
                                    : colors.disabledPrimary,
                              ),
                              duration: Motion.fast,
                              builder: (context, bg, _) => AppIconButton(
                                icon: AppIcons.send,
                                extent: control,
                                tint: colors.onPrimary,
                                backgroundColor: bg,
                                onPressed: _send,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 附件文件标签：图标 + 文件名 + 大小，可选删除按钮。输入栏和用户消息共用。
class FileChip extends StatelessWidget {
  const FileChip({
    super.key,
    required this.name,
    required this.size,
    this.onRemove,
    this.onPrimary = false,
  });

  final String name;
  final int size;
  final VoidCallback? onRemove;

  /// 放在主题色背景（用户气泡）上时用反色。
  final bool onPrimary;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final fg = onPrimary ? colors.onPrimary : colors.onSurface;
    final sub = onPrimary
        ? colors.onPrimary.withValues(alpha: 0.75)
        : colors.onSurfaceVariantSummary;
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: EdgeInsets.fromLTRB(10, 8, onRemove == null ? 12 : 4, 8),
      decoration: ShapeDecoration(
        color: onPrimary
            ? colors.onPrimary.withValues(alpha: 0.15)
            : colors.surfaceContainer,
        shape: const MiuixSquircleBorder(cornerRadius: 12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiuixIcon(vector: AppIcons.file, size: 20, tint: fg),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                MiuixText(
                  name,
                  fontSize: 13,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  color: fg,
                ),
                MiuixText(formatBytes(size), fontSize: 11, color: sub),
              ],
            ),
          ),
          if (onRemove != null)
            Tap(
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: MiuixIcon(vector: AppIcons.close, size: 14, tint: sub),
              ),
            ),
        ],
      ),
    );
  }
}

/// 提示词选择面板（输入 / 时出现在输入框上方）。
class PromptPanel extends ConsumerWidget {
  const PromptPanel({super.key, required this.query, required this.onPick});

  final String query;
  final ValueChanged<Prompt> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final q = query.trim().toLowerCase();
    final all = ref.watch(promptsProvider).value ?? const <Prompt>[];
    final matches = [
      for (final p in all)
        if (q.isEmpty ||
            p.title.toLowerCase().contains(q) ||
            p.content.toLowerCase().contains(q))
          p,
    ];
    Widget row(String title, String? summary, VoidCallback onTap) => Tap(
      sink: false,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MiuixText(title, fontSize: 14, fontWeight: FontWeight.w600),
            if (summary != null)
              MiuixText(
                summary,
                fontSize: 12,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                color: colors.onSurfaceVariantSummary,
              ),
          ],
        ),
      ),
    );
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: ShapeDecoration(
        color: colors.surfaceContainer,
        shape: const MiuixSquircleBorder(cornerRadius: 14),
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final p in matches)
            row(
              p.title,
              p.content.trim().replaceAll('\n', ' '),
              () => onPick(p),
            ),
          if (matches.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: MiuixText(
                '没有匹配的提示词',
                fontSize: 13,
                color: colors.onSurfaceVariantSummary,
              ),
            ),
          row(
            '管理提示词…',
            null,
            () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const PromptsPage())),
          ),
        ],
      ),
    );
  }
}
