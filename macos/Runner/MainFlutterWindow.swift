import Carbon
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    ICloudChannel.register(with: flutterViewController.registrar(forPlugin: "ICloudChannel"))
    GlobalHotkey.shared.attach(flutterViewController.registrar(forPlugin: "GlobalHotkey").messenger)

    super.awakeFromNib()
  }
}

/// iCloud 同步用的文件通道：只负责 iCloud 容器里的文件列表、读写和删除，
/// 合并逻辑在 Dart（lib/data/sync）。所有文件操作在后台队列，用 NSFileCoordinator 协调。
final class ICloudChannel: NSObject, FlutterPlugin {
  static let containerId = "iCloud.cn.oxoz.agent"
  private let queue = DispatchQueue(label: "cn.oxoz.agent.icloud", qos: .utility)
  private var cachedRoot: URL?

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "cn.oxoz.agent/icloud", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(ICloudChannel(), channel: channel)
  }

  /// 容器里的同步根目录（不在 Documents 下，不会出现在「文件」App 里）。
  private func root() -> URL? {
    if let r = cachedRoot { return r }
    guard FileManager.default.ubiquityIdentityToken != nil,
      let c = FileManager.default.url(forUbiquityContainerIdentifier: ICloudChannel.containerId)
    else { return nil }
    let r = c.appendingPathComponent("Sync", isDirectory: true)
    try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
    cachedRoot = r
    return r
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    queue.async {
      let value: Any?
      do {
        value = try self.run(call.method, args)
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "icloud", message: error.localizedDescription, details: nil))
        }
        return
      }
      DispatchQueue.main.async { result(value ?? NSNull()) }
    }
  }

  private func url(_ args: [String: Any]) throws -> URL {
    guard let r = root() else { throw NSError(domain: "icloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "iCloud 不可用"]) }
    let path = args["path"] as? String ?? ""
    return r.appendingPathComponent(path)
  }

  private func run(_ method: String, _ args: [String: Any]) throws -> Any? {
    switch method {
    case "available":
      return root() != nil
    case "list":
      let dir = try url(args)
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
      var out: [[String: Any]] = []
      for raw in names {
        // 还没下载到本机的文件以 .名字.icloud 占位。
        if raw.hasPrefix(".") && raw.hasSuffix(".icloud") {
          out.append(["name": String(raw.dropFirst().dropLast(7)), "downloaded": false])
        } else if !raw.hasPrefix(".") {
          let u = dir.appendingPathComponent(raw)
          let status = try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
          out.append(["name": raw, "downloaded": status == nil || status == .current])
        }
      }
      return out
    case "read":
      let u = try url(args)
      let fm = FileManager.default
      let placeholder = u.deletingLastPathComponent().appendingPathComponent(".\(u.lastPathComponent).icloud")
      if !fm.fileExists(atPath: u.path) && !fm.fileExists(atPath: placeholder.path) { return nil }
      try? fm.startDownloadingUbiquitousItem(at: u)
      // 等下载完成（最多 30 秒）。
      let deadline = Date().addingTimeInterval(30)
      while Date() < deadline {
        let status = try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        if fm.fileExists(atPath: u.path) && (status == nil || status == .current) { break }
        Thread.sleep(forTimeInterval: 0.25)
      }
      var data: Data?
      var coordError: NSError?
      var readError: Error?
      NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: u, options: [], error: &coordError) { r in
        do { data = try Data(contentsOf: r) } catch { readError = error }
      }
      if let e = coordError ?? readError as NSError? {
        if (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError) { return nil }
        throw e
      }
      guard let d = data else { return nil }
      return FlutterStandardTypedData(bytes: d)
    case "write":
      let u = try url(args)
      guard let bytes = args["bytes"] as? FlutterStandardTypedData else { return false }
      try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
      var coordError: NSError?
      var writeError: Error?
      NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: u, options: .forReplacing, error: &coordError) { w in
        do { try bytes.data.write(to: w, options: .atomic) } catch { writeError = error }
      }
      if let e = coordError ?? writeError { throw e }
      // 同名文件在多台设备上同时写入时 iCloud 会留下冲突版本：以当前版本为准，清掉其余。
      if let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: u), !conflicts.isEmpty {
        for v in conflicts { v.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: u)
      }
      return true
    case "delete":
      let u = try url(args)
      var coordError: NSError?
      NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: u, options: .forDeleting, error: &coordError) { d in
        try? FileManager.default.removeItem(at: d)
      }
      return true
    case "download":
      guard let r = root(), let paths = args["paths"] as? [String] else { return false }
      for p in paths { try? FileManager.default.startDownloadingUbiquitousItem(at: r.appendingPathComponent(p)) }
      return true
    default:
      return nil
    }
  }
}


/// 全局快捷键 ⌥ Space：在任何地方呼出窗口并新建对话。用 Carbon 的
/// RegisterEventHotKey，沙盒内可用，不需要辅助功能权限。
final class GlobalHotkey {
  static let shared = GlobalHotkey()
  private var channel: FlutterMethodChannel?
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?

  func attach(_ messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "cn.oxoz.agent/quick", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setHotkey":
        let on = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
        if on {
          result(self?.register() ?? false)
        } else {
          self?.unregister()
          result(true)
        }
      case "takePending":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  private func register() -> Bool {
    if hotKey != nil { return true }
    if handler == nil {
      var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        GlobalHotkey.shared.fire()
        return noErr
      }, 1, &spec, nil, &handler)
    }
    let id = EventHotKeyID(signature: OSType(0x5843_4147), id: 1)  // 'XCAG'
    let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    return status == noErr
  }

  private func unregister() {
    if let h = hotKey { UnregisterEventHotKey(h) }
    hotKey = nil
  }

  private func fire() {
    NSApp.activate(ignoringOtherApps: true)
    for w in NSApp.windows where w is MainFlutterWindow {
      if w.isMiniaturized { w.deminiaturize(nil) }
      w.makeKeyAndOrderFront(nil)
    }
    channel?.invokeMethod("hotkey", arguments: nil)
  }
}
