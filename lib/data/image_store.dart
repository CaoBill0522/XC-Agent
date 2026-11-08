import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/chat/chat_types.dart';
import 'ids.dart';

/// 聊天图片的本地存储（用户上传 + 模型生成）。数据库里只存文件名。
class ImageStore {
  ImageStore([Future<Directory> Function()? baseDir])
    : _baseDir = baseDir ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDir;
  Directory? _dir;

  Future<Directory> get dir async {
    if (_dir case final d?) return d;
    final d = Directory(p.join((await _baseDir()).path, 'images'));
    await d.create(recursive: true);
    return _dir = d;
  }

  Future<File> file(String name) async => File(p.join((await dir).path, name));

  Future<ImagePart> save(Uint8List bytes, String mime) async {
    final name = '${newId()}.${_ext(mime)}';
    await (await file(name)).writeAsBytes(bytes, flush: true);
    return ImagePart(name, mime);
  }

  Future<InlineImage?> readInline(ImagePart part) async {
    final f = await file(part.path);
    if (!await f.exists()) return null;
    return InlineImage(
      base64: base64Encode(await f.readAsBytes()),
      mime: part.mime,
    );
  }

  Future<void> delete(String name) async {
    final f = await file(name);
    if (await f.exists()) await f.delete();
  }

  static String _ext(String mime) => switch (mime) {
    'image/jpeg' => 'jpg',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    _ => 'png',
  };
}

/// 发送前处理图片：过大则缩放并转 JPEG，控制请求体积。返回 (bytes, mime)。
Future<(Uint8List, String)> prepareImageForUpload(Uint8List bytes) {
  return Isolate.run(() {
    final mime = sniffImageMime(bytes) ?? 'image/png';
    const maxSide = 2048;
    const maxBytes = 1536 * 1024;
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return (bytes, mime);
    final big = decoded.width > maxSide || decoded.height > maxSide;
    // GIF / 小图原样上传。
    if (mime == 'image/gif' || (!big && bytes.length <= maxBytes)) {
      return (bytes, mime);
    }

    final resized = big
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? maxSide : null,
            height: decoded.height > decoded.width ? maxSide : null,
            interpolation: img.Interpolation.average,
          )
        : decoded;
    return (
      Uint8List.fromList(img.encodeJpg(resized, quality: 85)),
      'image/jpeg',
    );
  });
}

/// 按文件头判断图片类型。
String? sniffImageMime(List<int> b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return 'image/gif';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}
