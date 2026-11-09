import AppIntents
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ICloudChannel") {
      ICloudChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "QuickAskBridge") {
      QuickAskBridge.shared.attach(registrar.messenger())
    }
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


/// Siri / 快捷指令「问 XC-Agent」→ Flutter：App 已启动时直接调过去，
/// 还没启动完时先存着，等 Flutter 端用 takePending 取走。
final class QuickAskBridge {
  static let shared = QuickAskBridge()
  private var channel: FlutterMethodChannel?
  private var pending: String??

  func attach(_ messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "cn.oxoz.agent/quick", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "takePending":
        if let p = self?.pending {
          self?.pending = nil
          result(["text": p as Any])
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  func deliver(_ text: String?) {
    DispatchQueue.main.async {
      if let ch = self.channel {
        ch.invokeMethod("ask", arguments: ["text": text as Any])
      } else {
        self.pending = .some(text)
      }
    }
  }
}

@available(iOS 16.0, *)
struct AskXCAgentIntent: AppIntent {
  static var title: LocalizedStringResource = "问 XC-Agent"
  static var description = IntentDescription("打开 XC-Agent 新建一个对话，可以带上要问的内容。")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "问题", requestValueDialog: "想问什么？")
  var text: String?

  @MainActor
  func perform() async throws -> some IntentResult {
    QuickAskBridge.shared.deliver(text)
    return .result()
  }
}

@available(iOS 16.0, *)
struct XCAgentShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AskXCAgentIntent(),
      phrases: [
        "问 \(.applicationName)",
        "用 \(.applicationName) 提问",
        "Ask \(.applicationName)",
      ],
      shortTitle: "提问",
      systemImageName: "bubble.left.and.text.bubble.right"
    )
  }
}
