// SVG → 透明背景 PNG（macOS 的 NSImage 能直接读 SVG）。用法：swift svg2png.swift in.svg out.png 边长
import AppKit
let svg = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let img = NSImage(data: svg) else { print("no svg support"); exit(1) }
let size = Int(CommandLine.arguments[3])!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = ns
// 原图 98×96，等比放进正方形并居中
let w = CGFloat(size), h = CGFloat(size) * 96 / 98
img.draw(in: NSRect(x: 0, y: (CGFloat(size) - h) / 2, width: w, height: h))
NSGraphicsContext.current = nil
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("ok")
