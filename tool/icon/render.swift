// XCAgent 图标的绘制（CoreGraphics，支持透明背景）。由 make_icons.py 调用：
// stdin 传入 JSON 任务列表，每项 {out, size, fg, bg?, scale, tile?, radius?}
//   fg / bg：十六进制颜色，bg 省略表示透明
//   scale：图形相对 1024 画布的缩放（以中心为基准）
//   tile：画圆角方块背景（macOS / Windows 图标自带形状），inset 为四周留白，radius 为圆角
import AppKit

struct Job: Decodable {
  let out: String
  let size: Int
  let fg: String
  let bg: String?
  let scale: Double
  let tile: Bool?
  let inset: Double?
  let radius: Double?
}

func color(_ hex: String) -> CGColor {
  let v = UInt32(hex.dropFirst(hex.hasPrefix("#") ? 1 : 0), radix: 16)!
  return CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                 blue: CGFloat(v & 255) / 255, alpha: 1)
}

func pt(_ c: CGPoint, _ r: Double, _ deg: Double) -> CGPoint {
  let a = deg * .pi / 180
  return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
}

/// 图形本体（1024 坐标系，y 向下）：右侧开口的 C 圆弧 + 节点相连的 X。
func drawMark(_ ctx: CGContext, fg: CGColor) {
  let c = CGPoint(x: 512, y: 512)
  ctx.setStrokeColor(fg)
  ctx.setFillColor(fg)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)

  // C：52° → 308°（顺时针，经过左侧）
  let arc = CGMutablePath()
  for i in 0...240 {
    let p = pt(c, 318, 52 + (308 - 52) * Double(i) / 240)
    i == 0 ? arc.move(to: p) : arc.addLine(to: p)
  }
  ctx.setLineWidth(64)
  ctx.addPath(arc)
  ctx.strokePath()

  // X：两条对角线，四个端点和中心是节点
  let xc = CGPoint(x: 524, y: 512)
  let ends = [225.0, 45, 135, 315].map { pt(xc, 150, $0) }
  ctx.setLineWidth(40)
  ctx.move(to: ends[0]); ctx.addLine(to: ends[1])
  ctx.move(to: ends[2]); ctx.addLine(to: ends[3])
  ctx.strokePath()
  for e in ends {
    ctx.fillEllipse(in: CGRect(x: e.x - 46, y: e.y - 46, width: 92, height: 92))
  }
  ctx.fillEllipse(in: CGRect(x: xc.x - 34, y: xc.y - 34, width: 68, height: 68))
}

let jobs = try! JSONDecoder().decode([Job].self, from: FileHandle.standardInput.readDataToEndOfFile())
for job in jobs {
  let s = job.size
  let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: job.bg == nil || job.tile == true
                        ? CGImageAlphaInfo.premultipliedLast.rawValue
                        : CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.interpolationQuality = .high
  ctx.setShouldAntialias(true)
  // 统一到 1024 坐标系，y 向下（与 SVG 一致）。
  let k = CGFloat(s) / 1024
  ctx.translateBy(x: 0, y: CGFloat(s))
  ctx.scaleBy(x: k, y: -k)

  if let bg = job.bg {
    ctx.setFillColor(color(bg))
    if job.tile == true {
      let inset = job.inset ?? 100
      let rect = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
      let r = job.radius ?? 185
      ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
      ctx.fillPath()
    } else {
      ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }
  }
  ctx.saveGState()
  ctx.translateBy(x: 512, y: 512)
  ctx.scaleBy(x: job.scale, y: job.scale)
  ctx.translateBy(x: -512, y: -512)
  drawMark(ctx, fg: color(job.fg))
  ctx.restoreGState()

  let url = URL(fileURLWithPath: job.out)
  try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
}
print("rendered \(jobs.count)")
