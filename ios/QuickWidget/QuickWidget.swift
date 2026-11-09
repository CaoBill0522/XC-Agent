import SwiftUI
import WidgetKit

/// 系统首选语言是中文时显示中文，否则英文。
private let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

/// 主屏 / 锁屏小组件：点一下打开 XCAgent 新建对话。
struct QuickEntry: TimelineEntry {
  let date: Date
}

struct QuickProvider: TimelineProvider {
  func placeholder(in context: Context) -> QuickEntry { QuickEntry(date: .now) }
  func getSnapshot(in context: Context, completion: @escaping (QuickEntry) -> Void) {
    completion(QuickEntry(date: .now))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<QuickEntry>) -> Void) {
    completion(Timeline(entries: [QuickEntry(date: .now)], policy: .never))
  }
}

struct QuickWidgetView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    content
      .widgetURL(URL(string: "xcagent://new"))
      .modifier(WidgetBackground())
  }

  @ViewBuilder private var content: some View {
    switch family {
    case .accessoryCircular:
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.title3)
      }
    case .accessoryRectangular:
      HStack(spacing: 6) {
        Image(systemName: "bubble.left.and.text.bubble.right.fill")
        Text(zh ? "问 XCAgent" : "Ask XCAgent").font(.headline)
      }
    default:
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: "bubble.left.and.text.bubble.right.fill")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(.tint)
        Spacer()
        Text("XCAgent").font(.headline)
        Text(zh ? "新建对话" : "New chat").font(.subheadline).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
  }
}

/// iOS 17 起小组件必须声明背景。
struct WidgetBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(.fill.tertiary, for: .widget)
    } else {
      content.padding()
    }
  }
}

struct QuickWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "QuickWidget", provider: QuickProvider()) { _ in
      QuickWidgetView()
    }
    .configurationDisplayName(zh ? "快速提问" : "Quick ask")
    .description(zh ? "一键打开 XCAgent 新建对话。" : "Open XCAgent with a new chat.")
    .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
  }
}

@main
struct QuickWidgetBundle: WidgetBundle {
  var body: some Widget { QuickWidget() }
}
