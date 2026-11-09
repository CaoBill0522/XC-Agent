import UIKit
import UniformTypeIdentifiers

/// 系统分享面板里的「XC-Agent」：把分享的文字 / 链接带进 App，新建一个对话并填进输入框。
/// 没有界面，取到内容后直接打开主 App。
final class ShareViewController: UIViewController {
  private var handled = false

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !handled else { return }
    handled = true
    Task { await handle() }
  }

  private func handle() async {
    var parts: [String] = []
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    for item in items {
      if let text = item.attributedContentText?.string, !text.isEmpty { parts.append(text) }
      for provider in item.attachments ?? [] {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
          let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
        {
          parts.append(url.absoluteString)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
        {
          parts.append(text)
        }
      }
    }
    // 去重（网页分享时标题和链接可能各来一次）并限制长度，链接太长会打不开。
    var seen = Set<String>()
    let text = parts.filter { seen.insert($0).inserted }.joined(separator: "\n")
    let clipped = String(text.prefix(6000))
    var components = URLComponents()
    components.scheme = "xcagent"
    components.host = "ask"
    components.queryItems = [URLQueryItem(name: "text", value: clipped)]
    if let url = components.url { openHostApp(url) }
    extensionContext?.completeRequest(returningItems: nil)
  }

  /// 扩展里没有 UIApplication.shared，顺着响应链找到 UIApplication 再调用打开链接。
  private func openHostApp(_ url: URL) {
    var responder: UIResponder? = self
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    while let r = responder {
      if let app = r as? UIApplication, app.responds(to: selector) {
        typealias Open = @convention(c) (AnyObject, Selector, URL, NSDictionary, Any?) -> Void
        let imp = app.method(for: selector)
        unsafeBitCast(imp, to: Open.self)(app, selector, url, NSDictionary(), nil)
        return
      }
      responder = r.next
    }
  }
}
