import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'db/app_database.dart';
import 'secure/key_store.dart';
import '../l10n/tr.dart';

/// 配置导入导出：渠道、模型、路由、助手（不含聊天记录）。
class ConfigTransfer {
  ConfigTransfer(this._db, this._keys);

  final AppDatabase _db;
  final KeyStore _keys;

  static const format = 'cn.oxoz.agent/config';
  static const version = 1;

  /// 旧版导出（只做了 gzip + base64url 编码，没有加密）。仍可导入。
  static const prefix = 'XCAGENT1:';

  /// 加密导出：`XCAGENT2:` + base64url(盐 16 字节 ‖ 随机数 12 字节 ‖ 密文 ‖ 校验 16 字节)。
  /// 明文是 gzip 压缩后的 JSON；密钥由密码经 PBKDF2-HMAC-SHA256 派生，
  /// 用 AES-256-GCM 加密（自带完整性校验，密码错误或内容被改动都会解不开）。
  static const encryptedPrefix = 'XCAGENT2:';
  static const pbkdf2Iterations = 120000;

  /// 导出全部配置（含 API Key），用 [password] 加密成一串文本。
  Future<String> export(String password) async {
    final plain = await exportJson();
    return Isolate.run(() => encrypt(plain, password));
  }

  /// 导出内容加密前的 JSON。
  Future<String> exportJson() async {
    final channels = await _db.select(_db.channels).get();
    final keys = <String, String>{};
    for (final c in channels) {
      final k = await _keys.read(c.id);
      if (k != null && k.isNotEmpty) keys[c.id] = k;
    }
    final json = jsonEncode({
      'format': format,
      'version': version,
      'channels': [
        for (final c in channels) {...c.toJson(), 'apiKey': ?keys[c.id]},
      ],
      'models': [
        for (final m in await _db.select(_db.models).get()) m.toJson(),
      ],
      'routes': [
        for (final r in await _db.select(_db.modelRoutes).get()) r.toJson(),
      ],
      'agents': [
        for (final a in await _db.select(_db.agents).get()) a.toJson(),
      ],
    });
    return json;
  }

  static Future<SecretKey> _deriveKey(String password, List<int> salt) =>
      Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: pbkdf2Iterations,
        bits: 256,
      ).deriveKeyFromPassword(password: password, nonce: salt);

  static Future<String> encrypt(String json, String password) async {
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    final key = await _deriveKey(password, salt);
    final aes = AesGcm.with256bits();
    final box = await aes.encrypt(
      gzip.encode(utf8.encode(json)),
      secretKey: key,
      nonce: aes.newNonce(),
    );
    final bytes = BytesBuilder()
      ..add(salt)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return encryptedPrefix + base64Url.encode(bytes.takeBytes());
  }

  static String _clean(String t) => t.replaceAll(RegExp(r'\s'), '');

  /// 是否加密格式（导入前需要先问密码）。
  static bool isEncrypted(String text) =>
      text.trim().startsWith(encryptedPrefix);

  /// 解开加密导出的文本。格式不对或密码错误时抛 [FormatException]。
  static Future<Map<String, dynamic>> decrypt(
    String text,
    String password,
  ) async {
    // 在后台 isolate 里跑（PBKDF2 计算量大）；那边没有界面语言设置，
    // 只回传错误代码，提示文字在这里翻译。
    final r = await Isolate.run(() => _decrypt(text, password));
    return switch (r) {
      final Map<String, dynamic> json => json,
      'password' => throw FormatException(tr('密码不对，或者内容不完整')),
      _ => throw FormatException(tr('剪贴板内容不是有效的配置')),
    };
  }

  static Future<Object> _decrypt(String text, String password) async {
    final List<int> bytes;
    try {
      bytes = base64Url.decode(
        base64Url.normalize(
          _clean(text.trim().substring(encryptedPrefix.length)),
        ),
      );
    } catch (_) {
      return 'format';
    }
    if (bytes.length < 16 + 12 + 16) return 'format';
    final box = SecretBox(
      bytes.sublist(28, bytes.length - 16),
      nonce: bytes.sublist(16, 28),
      mac: Mac(bytes.sublist(bytes.length - 16)),
    );
    try {
      final plain = await AesGcm.with256bits().decrypt(
        box,
        secretKey: await _deriveKey(password, bytes.sublist(0, 16)),
      );
      return jsonDecode(utf8.decode(gzip.decode(plain)))
          as Map<String, dynamic>;
    } on SecretBoxAuthenticationError {
      return 'password';
    } catch (_) {
      return 'format';
    }
  }

  /// 解码未加密的导出文本（旧版编码格式或明文 JSON）。
  static Map<String, dynamic> decode(String text) {
    final t = text.trim();
    try {
      final raw = t.startsWith(prefix)
          ? utf8.decode(
              gzip.decode(
                base64Url.decode(
                  base64Url.normalize(
                    t.substring(prefix.length).replaceAll(RegExp(r'\s'), ''),
                  ),
                ),
              ),
            )
          : t;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw FormatException(tr('剪贴板内容不是有效的配置'));
    }
  }

  /// 导入（按 ID 覆盖同名记录）。加密格式需要 [password]。返回导入的条目数说明。
  Future<String> import(String text, {String? password}) async {
    final json = isEncrypted(text)
        ? await decrypt(text, password ?? '')
        : decode(text);
    if (json['format'] != format) throw FormatException(tr('不是本应用导出的配置'));

    List<Map<String, dynamic>> list(String k) => [
      for (final e in (json[k] as List? ?? const [])) e as Map<String, dynamic>,
    ];

    final channels = list('channels');
    final models = list('models');
    final routes = list('routes');
    final agents = list('agents');
    var keys = 0;

    await _db.transaction(() async {
      for (final c in channels) {
        await _db
            .into(_db.channels)
            .insertOnConflictUpdate(Channel.fromJson(c));
      }
      for (final m in models) {
        await _db.into(_db.models).insertOnConflictUpdate(Model.fromJson(m));
      }
      for (final r in routes) {
        await _db
            .into(_db.modelRoutes)
            .insertOnConflictUpdate(ModelRoute.fromJson(r));
      }
      for (final a in agents) {
        await _db.into(_db.agents).insertOnConflictUpdate(Agent.fromJson(a));
      }
    });
    for (final c in channels) {
      if (c['apiKey'] case final String k when k.isNotEmpty) {
        await _keys.write(c['id'] as String, k);
        keys++;
      }
    }
    return trArgs('已导入 {0} 个渠道（含 {1} 个 Key）、{2} 个模型、{3} 个助手', [
      channels.length,
      keys,
      models.length,
      agents.length,
    ]);
  }

  Future<void> clearChats() => _db.transaction(() async {
    await _db.delete(_db.messages).go();
    await _db.delete(_db.conversations).go();
  });
}
