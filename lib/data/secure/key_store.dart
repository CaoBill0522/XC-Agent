import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// API Key 存储，以渠道 ID 为索引。
abstract class KeyStore {
  Future<String?> read(String channelId);
  Future<void> write(String channelId, String apiKey);
  Future<void> delete(String channelId);
}

/// 走系统安全存储（iOS/macOS Keychain、Android Keystore、Windows DPAPI），不进 SQLite。
///
/// iOS 上可选「通过 iCloud 钥匙串同步」（[syncKeys] 返回 true）：写入可同步的钥匙串项，
/// 同一 Apple ID 的其它设备能直接读到。读取时先找可同步的，再找仅本机的。
class SecureKeyStore implements KeyStore {
  SecureKeyStore([FlutterSecureStorage? storage, this.syncKeys])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // macOS：用传统 Keychain，免去 keychain-access-groups 权限和描述文件，
            // 否则未签名 / 免费账号构建的 App 无法写入或无法分发。
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _storage;
  final bool Function()? syncKeys;

  /// 可同步的钥匙串项不能用「仅本设备」的访问级别。
  static const _synced = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
    synchronizable: true,
  );

  static String _key(String channelId) => 'channel_api_key:$channelId';

  @override
  Future<String?> read(String channelId) async {
    if (Platform.isIOS) {
      try {
        final v = await _storage.read(key: _key(channelId), iOptions: _synced);
        if (v != null) return v;
      } catch (_) {}
    }
    return _storage.read(key: _key(channelId));
  }

  @override
  Future<void> write(String channelId, String apiKey) async {
    final key = _key(channelId);
    if (Platform.isIOS) {
      // 先删掉两种存法的旧值，避免读到另一份过期的。
      await _storage.delete(key: key);
      if (syncKeys?.call() ?? false) {
        return _storage.write(key: key, value: apiKey, iOptions: _synced);
      }
    }
    return _storage.write(key: key, value: apiKey);
  }

  @override
  Future<void> delete(String channelId) =>
      _storage.delete(key: _key(channelId));
}

/// 内存实现，用于测试。
class MemoryKeyStore implements KeyStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String channelId) async => values[channelId];

  @override
  Future<void> write(String channelId, String apiKey) async =>
      values[channelId] = apiKey;

  @override
  Future<void> delete(String channelId) async => values.remove(channelId);
}
