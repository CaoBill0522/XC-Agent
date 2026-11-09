import SwiftUI
import WidgetKit

/// 主屏 / 锁屏小组件：点一下打开 XC-Agent 新建对话。
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
        Text("问 XC-Agent").font(.headline)
      }
    default:
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: "bubble.left.and.text.bubble.right.fill")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(.tint)
        Spacer()
        Text("XC-Agent").font(.headline)
        Text("新建对话").font(.subheadline).foregroundStyle(.secondary)
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
    .configurationDisplayName("快速提问")
    .description("一键打开 XC-Agent 新建对话。")
    .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
  }
}

@main
struct QuickWidgetBundle: WidgetBundle {
  var body: some Widget { QuickWidget() }
}
