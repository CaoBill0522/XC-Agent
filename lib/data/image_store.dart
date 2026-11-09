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

  /// 保存附件，文件名保留原扩展名。
  Future<FilePart> saveFile(Uint8List bytes, String name, String mime) async {
    final ext = p.extension(name);
    final stored = '${newId()}${ext.length <= 8 ? ext : ''}';
    await (await file(stored)).writeAsBytes(bytes, flush: true);
    return FilePart(stored, name, mime, bytes.length);
  }

  Future<Uint8List?> readBytes(String name) async {
    final f = await file(name);
    return await f.exists() ? f.readAsBytes() : null;
  }

  /// 复制一份（对话分支时，两个对话各自持有文件，删除互不影响）。
  Future<String?> duplicate(String name) async {
    final src = await file(name);
    if (!await src.exists()) return null;
    final copy = '${newId()}${p.extension(name)}';
    await src.copy((await file(copy)).path);
    return copy;
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

/// 附件类型：文本类文件把内容并入问题；PDF 原样发给模型。
enum AttachmentKind { text, pdf }

/// 可以作为附件的文本文件扩展名。
const textFileExtensions = {
  'txt',
  'md',
  'markdown',
  'csv',
  'tsv',
  'json',
  'jsonl',
  'yaml',
  'yml',
  'xml',
  'html',
  'htm',
  'css',
  'log',
  'ini',
  'toml',
  'conf',
  'env',
  'sql',
  'dart',
  'py',
  'js',
  'ts',
  'jsx',
  'tsx',
  'java',
  'kt',
  'kts',
  'swift',
  'm',
  'mm',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'cs',
  'go',
  'rs',
  'rb',
  'php',
  'sh',
  'bash',
  'zsh',
  'ps1',
  'bat',
  'lua',
  'r',
  'scala',
  'vue',
  'svelte',
  'gradle',
  'properties',
  'tex',
  'srt',
  'vtt',
};

/// 文本附件大小上限（约 50 万字符），PDF 上限 32MB。
const maxTextFileBytes = 512 * 1024;
const maxPdfBytes = 32 * 1024 * 1024;

/// 判断附件类型；不支持的返回 null。
AttachmentKind? attachmentKind(String name, Uint8List bytes) {
  final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
  final isPdf =
      ext == 'pdf' ||
      (bytes.length >= 4 &&
          bytes[0] == 0x25 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x44 &&
          bytes[3] == 0x46);
  if (isPdf) return AttachmentKind.pdf;
  if (textFileExtensions.contains(ext)) return AttachmentKind.text;
  // 没有扩展名或不认识的：看起来是 UTF-8 文本也接受。
  if (bytes.length <= maxTextFileBytes && !bytes.contains(0)) {
    try {
      utf8.decode(bytes);
      return AttachmentKind.text;
    } catch (_) {}
  }
  return null;
}

/// 把文本附件拼进问题里发给模型。
String fileAsPrompt(String name, String content) {
  final fence = content.contains('```') ? '~~~~' : '```';
  return '【附件：$name】\n$fence\n${content.trimRight()}\n$fence';
}

/// 300 → 300 B，2048 → 2.0 KB。
String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
}
