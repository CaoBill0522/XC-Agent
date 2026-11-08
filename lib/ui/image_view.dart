import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';

import '../core/chat/chat_types.dart';
import '../data/providers.dart';
import 'app_icons.dart';
import 'motion.dart';

/// 本地图片缩略图（点击全屏查看）。
class LocalImage extends ConsumerWidget {
  const LocalImage(
    this.part, {
    super.key,
    this.size = 160,
    this.fit = BoxFit.cover,
  });

  final ImagePart part;
  final double size;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<File>(
      future: ref.read(imageStoreProvider).file(part.path),
      builder: (context, snap) {
        final file = snap.data;
        final colors = MiuixTheme.of(context).colors;
        return Tap(
          onTap: file == null
              ? null
              : () => Navigator.of(
                  context,
                  rootNavigator: true,
                ).push(fadeRoute(ImageViewer(file: file, mime: part.mime))),
          child: ClipPath(
            clipper: const ShapeBorderClipper(
              shape: MiuixSquircleBorder(cornerRadius: 14),
            ),
            child: SizedBox(
              width: size,
              height: size,
              child: file == null
                  ? ColoredBox(color: colors.surfaceContainerHigh)
                  : Image.file(
                      file,
                      fit: fit,
                      cacheWidth:
                          (size * MediaQuery.devicePixelRatioOf(context))
                              .round(),
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: colors.surfaceContainerHigh,
                        child: Center(
                          child: MiuixIcon(
                            vector: AppIcons.image,
                            tint: colors.onSurfaceVariantSummary,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// 内存中的图片缩略图（待发送的附件）。
class MemoryThumb extends StatelessWidget {
  const MemoryThumb(this.bytes, {super.key, this.size = 64, this.onRemove});

  final Uint8List bytes;
  final double size;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipPath(
          clipper: const ShapeBorderClipper(
            shape: MiuixSquircleBorder(cornerRadius: 12),
          ),
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
          ),
        ),
        if (onRemove != null)
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: colors.onSurface.withValues(alpha: 0.7),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: MiuixIcon(
                    vector: AppIcons.close,
                    size: 14,
                    tint: colors.surface,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 全屏查看图片：可缩放，可保存。
class ImageViewer extends StatelessWidget {
  const ImageViewer({super.key, required this.file, required this.mime});

  final File file;
  final String mime;

  Future<void> _save(BuildContext context, MiuixSnackbarHostState snack) async {
    try {
      if (Platform.isIOS || Platform.isAndroid) {
        if (!await Gal.hasAccess(toAlbum: false)) await Gal.requestAccess();
        await Gal.putImage(file.path);
        snack.showSnackbar('已保存到相册');
      } else {
        final ext = mime.split('/').last.replaceAll('jpeg', 'jpg');
        final loc = await getSaveLocation(suggestedName: 'image.$ext');
        if (loc == null) return;
        await file.copy(loc.path);
        snack.showSnackbar('已保存');
      }
    } catch (e) {
      snack.showSnackbar('保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final snack = MiuixSnackbarHostState();
    final padding = MediaQuery.paddingOf(context);
    return MiuixScaffold(
      containerColor: Colors.black,
      snackbarHost: MiuixSnackbarHost(state: snack),
      content: (_) => Stack(
        children: [
          Positioned.fill(
            child: Tap(
              onTap: () => Navigator.of(context).pop(),
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(child: Image.file(file)),
              ),
            ),
          ),
          Positioned(
            top: padding.top + 8,
            right: 12,
            child: Row(
              children: [
                AppIconButton(
                  icon: AppIcons.download,
                  tint: Colors.white,
                  onPressed: () => _save(context, snack),
                ),
                AppIconButton(
                  icon: AppIcons.close,
                  tint: Colors.white,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
