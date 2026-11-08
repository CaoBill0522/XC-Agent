import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// API Key 存储，以渠道 ID 为索引。
abstract class KeyStore {
  Future<String?> read(String channelId);
  Future<void> write(String channelId, String apiKey);
  Future<void> delete(String channelId);
}

/// 走系统安全存储（iOS/macOS Keychain、Android Keystore、Windows DPAPI），不进 SQLite。
class SecureKeyStore implements KeyStore {
  SecureKeyStore([FlutterSecureStorage? storage])
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

  static String _key(String channelId) => 'channel_api_key:$channelId';

  @override
  Future<String?> read(String channelId) => _storage.read(key: _key(channelId));

  @override
  Future<void> write(String channelId, String apiKey) =>
      _storage.write(key: _key(channelId), value: apiKey);

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
