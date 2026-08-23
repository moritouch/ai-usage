import AppKit
import CoreGraphics
import CoreText
import Foundation

// アプリアイコンを描いて .iconset を吐く。
// 意匠: 下が開いた 240° のゲージ。アプリ内のバーと同じ緑→黄→赤の配色を使う。

let canvas = 1024.0
let inset = 100.0                    // macOS の角丸アイコンは周囲に余白を取る
let plate = canvas - inset * 2
let cornerRadius = 185.0

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let calm = (0.24, 0.78, 0.51)
let moderate = (0.95, 0.76, 0.22)
let critical = (0.94, 0.33, 0.35)

/// 3 色を 0...1 で線形補間。
func rampColor(_ t: Double) -> CGColor {
    let clamped = min(max(t, 0), 1)
    let (from, to, local): ((Double, Double, Double), (Double, Double, Double), Double) =
        clamped < 0.5
        ? (calm, moderate, clamped / 0.5)
        : (moderate, critical, (clamped - 0.5) / 0.5)
    return srgb(
        from.0 + (to.0 - from.0) * local,
        from.1 + (to.1 - from.1) * local,
        from.2 + (to.2 - from.2) * local
    )
}


/// アイコンの文字に使うフォント。
/// PNG に焼いてからバンドルするので、これが要るのはビルドするマシンだけ。
/// 配布先には影響しない。
func iconFont(pointSize: CGFloat) -> NSFont {
    let candidates = ["NotoSansJP-Black", "NotoSansJP-Bold", "NotoSans-Black", "NotoSans-Bold"]
    for name in candidates {
        if let font = NSFont(name: name, size: pointSize) { return font }
    }
    FileHandle.standardError.write(Data(
        "warning: Noto Sans が見つかりません。システムフォントで描画します。\n".utf8))
    let base = NSFont.systemFont(ofSize: pointSize, weight: .heavy)
    return base.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: pointSize) } ?? base
}

/// 弧の内側に文字を置く。
///
/// 和文フォントは行の高さが欧文より大きく、ascent/descent で中央を取ると上にずれる。
/// 実際の字形の外接矩形（ink bounds）を基準に合わせる。
func drawCentered(_ text: String, in context: CGContext,
                  center: CGPoint, pointSize: CGFloat) {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: iconFont(pointSize: pointSize),
        .foregroundColor: NSColor.white,
        .kern: -pointSize * 0.02,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    // ink は描画原点からの相対なので、その中心を center に合わせる
    context.textPosition = CGPoint(x: center.x - ink.midX,
                                   y: center.y - ink.midY)
    CTLineDraw(line, context)
}

func makeImage(size: Double) -> CGImage {
    let scale = size / canvas
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // --- 台座 ---
    let plateRect = CGRect(x: inset, y: inset, width: plate, height: plate)
    let platePath = CGPath(roundedRect: plateRect,
                           cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                           transform: nil)
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let backdrop = CGGradient(
        colorsSpace: space,
        colors: [srgb(0.16, 0.17, 0.21), srgb(0.05, 0.05, 0.07)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        backdrop,
        start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0),
        options: []
    )
    context.restoreGState()

    // 上端のふちに軽くハイライトを入れて板っぽさを出す
    context.saveGState()
    context.addPath(platePath)
    context.setLineWidth(3)
    context.setStrokeColor(srgb(1, 1, 1, 0.10))
    context.strokePath()
    context.restoreGState()

    // --- ゲージ ---
    let center = CGPoint(x: canvas / 2, y: canvas / 2 - 40)
    let radius = 268.0
    let lineWidth = 104.0
    let startAngle = 210.0 * .pi / 180      // 左下
    let sweep = 240.0 * .pi / 180           // 上を通って右下まで
    let filled = 0.66                        // 塗り分けの位置

    context.setLineCap(.round)
    context.setLineWidth(lineWidth)

    // 軌道
    context.setStrokeColor(srgb(1, 1, 1, 0.11))
    context.addArc(center: center, radius: radius,
                   startAngle: startAngle, endAngle: startAngle - sweep,
                   clockwise: true)
    context.strokePath()

    // 塗り。円弧に沿った階調は細かい区間の連続で表現する。
    let steps = 160
    let fillSweep = sweep * filled
    for step in 0..<steps {
        let t0 = Double(step) / Double(steps)
        let t1 = Double(step + 1) / Double(steps)
        // 区間を少し重ねて継ぎ目を消す
        let a0 = startAngle - fillSweep * t0
        let a1 = startAngle - fillSweep * min(t1 + 0.35 / Double(steps), 1)
        context.setStrokeColor(rampColor(t0 * filled / 0.9))
        context.setLineCap(step == 0 || step == steps - 1 ? .round : .butt)
        context.addArc(center: center, radius: radius,
                       startAngle: a0, endAngle: a1, clockwise: true)
        context.strokePath()
    }

    // --- 文字 ---
    drawCentered("AI", in: context, center: CGPoint(x: center.x, y: center.y - 6),
                 pointSize: 214)

    return context.makeImage()!
}

// --- 書き出し ---
let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir,
                                         withIntermediateDirectories: true)

let variants: [(name: String, size: Double)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = makeImage(size: variant.size)
    let url = URL(fileURLWithPath: "\(outputDir)/\(variant.name).png")
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: variant.size, height: variant.size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try! data.write(to: url)
    print("  \(variant.name).png  (\(Int(variant.size))px)")
}
