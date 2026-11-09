import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../ids.dart';
import '../image_store.dart';
import '../secure/key_store.dart';
import 'cloud_store.dart';
import 'sync_engine.dart';

/// iCloud 同步的调度：打开开关后，启动时、回到前台时、本地数据变化后
/// （停 8 秒没有新变化）以及前台每 3 分钟各同步一次。
class SyncService extends ChangeNotifier with WidgetsBindingObserver {
  SyncService(
    this._db,
    this._images,
    this._prefsOf,
    this._keys, {
    CloudStore? cloud,
  }) : _cloud = cloud ?? ICloudStore();

  final AppDatabase _db;
  final ImageStore _images;
  final SharedPreferences Function() _prefsOf;
  final KeyStore _keys;
  final CloudStore _cloud;

  SharedPreferences get _prefs => _prefsOf();

  static const _enabledKey = 'icloud_sync';
  static const _keysKey = 'icloud_sync_keys';
  static const _lastKey = 'icloud_last_sync';
  static const _deviceKey = 'sync_device_id';

  static bool get supported => ICloudStore.supported;

  bool get enabled => _prefs.getBool(_enabledKey) ?? false;

  /// API Key 是否通过 iCloud 钥匙串同步（只在 iOS 上有效）。
  bool get syncKeys => _prefs.getBool(_keysKey) ?? false;

  DateTime? get lastSync => switch (_prefs.getInt(_lastKey)) {
    final ms? => DateTime.fromMillisecondsSinceEpoch(ms),
    null => null,
  };

  bool syncing = false;
  String? lastError;
  SyncReport? lastReport;

  String get _deviceId {
    var id = _prefs.getString(_deviceKey);
    if (id == null) {
      id = newId();
      _prefs.setString(_deviceKey, id);
    }
    return id;
  }

  Timer? _periodic;
  Timer? _debounce;
  StreamSubscription<void>? _changes;
  bool _started = false;

  /// 同步写库期间及刚结束时的本地变化是同步自己造成的，不再触发同步。
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    if (_started || !supported) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    try {
      if (enabled) _activate();
    } catch (_) {
      // 测试环境没有偏好存储。
    }
  }

  void _activate() {
    _periodic ??= Timer.periodic(const Duration(minutes: 3), (_) => syncNow());
    _changes ??= _db.tableUpdates(const TableUpdateQuery.any()).listen((_) {
      if (syncing || DateTime.now().isBefore(_quietUntil)) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 8), syncNow);
    });
    Timer(const Duration(seconds: 2), syncNow);
  }

  void _deactivate() {
    _periodic?.cancel();
    _periodic = null;
    _debounce?.cancel();
    _changes?.cancel();
    _changes = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      if (!enabled) return;
    } catch (_) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _periodic ??= Timer.periodic(
        const Duration(minutes: 3),
        (_) => syncNow(),
      );
      syncNow();
    } else if (state == AppLifecycleState.paused) {
      // 后台不轮询；离开前把刚改的内容传上去。
      _periodic?.cancel();
      _periodic = null;
      if (_debounce?.isActive ?? false) {
        _debounce!.cancel();
        syncNow();
      }
    }
  }

  /// 打开同步：先确认 iCloud 可用。返回错误提示，成功返回 null。
  Future<String?> setEnabled(bool on) async {
    if (on) {
      if (!await _cloud.available()) {
        return 'iCloud 不可用：请确认这台设备已登录 iCloud，并在「设置 → Apple 账户 → iCloud」里打开 iCloud 云盘';
      }
      await _prefs.setBool(_enabledKey, true);
      _activate();
      notifyListeners();
      return null;
    }
    await _prefs.setBool(_enabledKey, false);
    _deactivate();
    notifyListeners();
    return null;
  }

  /// 打开时把已有的 API Key 重新写一遍（写成可同步的钥匙串项）。
  Future<void> setSyncKeys(bool on) async {
    await _prefs.setBool(_keysKey, on);
    if (on) {
      for (final c in await _db.select(_db.channels).get()) {
        final key = await _keys.read(c.id);
        if (key != null && key.isNotEmpty) await _keys.write(c.id, key);
      }
    }
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (!enabled || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      final engine = SyncEngine(
        _db,
        _cloud,
        _images,
        deviceId: _deviceId,
        deviceName: _deviceName(),
      );
      lastReport = await engine.sync();
      lastError = null;
      await _prefs.setInt(_lastKey, DateTime.now().millisecondsSinceEpoch);
    } on SyncException catch (e) {
      lastError = e.message;
    } catch (e) {
      lastError = '同步失败：$e';
    } finally {
      syncing = false;
      _quietUntil = DateTime.now().add(const Duration(seconds: 2));
      notifyListeners();
    }
  }

  static String _deviceName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return Platform.operatingSystem;
    }
  }

  @override
  void dispose() {
    _deactivate();
    if (_started) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
