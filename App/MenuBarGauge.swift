import SwiftUI

/// メニューバー用のゲージ。アプリアイコンと同じ 240° の弧を、使用率ぶんだけ塗る。
/// MenuBarExtra のラベルは複雑なビューを確実に描けないため、画像に焼いてから渡す。
enum MenuBarGauge {
    static let side: CGFloat = 17

    @MainActor
    static func image(percent: Double) -> NSImage? {
        let renderer = ImageRenderer(
            content: GaugeGlyph(percent: percent).frame(width: side, height: side)
        )
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        // テンプレート指定にすると単色化されて逼迫度の色が消えるので、あえて外す。
        let image = NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
        image.isTemplate = false
        return image
    }
}

struct GaugeGlyph: View {
    let percent: Double

    var body: some View {
        ZStack {
            GaugeArc(fraction: 1)
                .stroke(Color.primary.opacity(0.28),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
            GaugeArc(fraction: min(max(percent, 0), 100) / 100)
                .stroke(UsageSeverity.of(percent).color,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

/// 下が開いた 240° の弧。SwiftUI は y 下向きなので、角度が増える向きが見た目の時計回り。
struct GaugeArc: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY + 1)
        let radius = min(rect.width, rect.height) / 2 - 2.2
        let start = Angle(degrees: 150)                     // 左下から
        let end = start + Angle(degrees: 240 * fraction)    // 上を通って右下へ
        path.addArc(center: center, radius: radius,
                    startAngle: start, endAngle: end, clockwise: false)
        return path
    }
}
