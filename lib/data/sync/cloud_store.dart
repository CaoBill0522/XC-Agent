import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 云端目录里的一个文件。[downloaded] 为 false 表示 iCloud 还没把它下载到本机。
class CloudEntry {
  const CloudEntry(this.name, {this.downloaded = true});
  final String name;
  final bool downloaded;
}

/// 同步用的远端文件存储。路径都用 `/` 分隔、相对同步根目录。
abstract class CloudStore {
  Future<bool> available();
  Future<List<CloudEntry>> list(String dir);

  /// 文件不存在时返回 null。iCloud 上未下载的文件会先下载。
  Future<Uint8List?> read(String path);
  Future<void> write(String path, Uint8List bytes);
  Future<void> delete(String path);

  /// 提前让 iCloud 开始下载（批量读取前调用，后面逐个读时不用一个个等）。
  Future<void> prefetch(List<String> paths) async {}
}

/// iCloud Drive 的 App 专属容器（原生代码见 ios/Runner/AppDelegate.swift）。
class ICloudStore extends CloudStore {
  static const _channel = MethodChannel('cn.oxoz.agent/icloud');

  /// 只有 iOS / macOS 有 iCloud。
  static bool get supported => Platform.isIOS || Platform.isMacOS;

  @override
  Future<bool> available() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<List<CloudEntry>> list(String dir) async {
    final r =
        await _channel.invokeListMethod<Map>('list', {'path': dir}) ?? const [];
    return [
      for (final e in r)
        CloudEntry(e['name'] as String, downloaded: e['downloaded'] != false),
    ];
  }

  @override
  Future<Uint8List?> read(String path) =>
      _channel.invokeMethod<Uint8List>('read', {'path': path});

  @override
  Future<void> write(String path, Uint8List bytes) =>
      _channel.invokeMethod('write', {'path': path, 'bytes': bytes});

  @override
  Future<void> delete(String path) =>
      _channel.invokeMethod('delete', {'path': path});

  @override
  Future<void> prefetch(List<String> paths) async {
    if (paths.isEmpty) return;
    await _channel.invokeMethod('download', {'paths': paths});
  }
}

/// 普通文件夹实现：测试用，也可以指向任意同步盘目录。
class DirectoryCloudStore extends CloudStore {
  DirectoryCloudStore(this.root);
  final Directory root;

  File _file(String path) => File(p.joinAll([root.path, ...path.split('/')]));

  @override
  Future<bool> available() async => true;

  @override
  Future<List<CloudEntry>> list(String dir) async {
    final d = Directory(p.joinAll([root.path, ...dir.split('/')]));
    if (!await d.exists()) return const [];
    return [
      await for (final e in d.list())
        if (e is File) CloudEntry(p.basename(e.path)),
    ];
  }

  @override
  Future<Uint8List?> read(String path) async {
    final f = _file(path);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final f = _file(path);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String path) async {
    final f = _file(path);
    if (await f.exists()) await f.delete();
  }
}
