#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasWidth = 800
private let canvasHeight = 500

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

private func rectFromTop(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: x, y: CGFloat(canvasHeight) - y - height, width: width, height: height)
}

private func drawText(
    _ value: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left,
    lineSpacing: CGFloat = 0
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = lineSpacing
    value.draw(
        in: rect,
        withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    )
}

private func drawArrow() {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 302, y: 374))
    path.line(to: NSPoint(x: 493, y: 374))
    path.lineWidth = 7
    path.lineCapStyle = .round
    color(0x65D6B0).setStroke()
    path.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 493, y: 374))
    head.line(to: NSPoint(x: 469, y: 391))
    head.move(to: NSPoint(x: 493, y: 374))
    head.line(to: NSPoint(x: 469, y: 357))
    head.lineWidth = 7
    head.lineCapStyle = .round
    color(0xF2C44E).setStroke()
    head.stroke()
}

private struct Step {
    let number: String
    let title: String
    let japanese: String
    let english: String
}

private func drawStep(_ step: Step, x: CGFloat, y: CGFloat) {
    let card = NSBezierPath(roundedRect: rectFromTop(x: x, y: y, width: 368, height: 94), xRadius: 15, yRadius: 15)
    color(0x303641, alpha: 0.96).setFill()
    card.fill()
    color(0xFFFFFF, alpha: 0.08).setStroke()
    card.lineWidth = 1
    card.stroke()

    let badgeRect = rectFromTop(x: x + 15, y: y + 15, width: 30, height: 30)
    let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 10, yRadius: 10)
    color(0x65D6B0, alpha: 0.16).setFill()
    badge.fill()
    drawText(
        step.number,
        in: rectFromTop(x: x + 15, y: y + 18, width: 30, height: 24),
        font: .systemFont(ofSize: 16, weight: .bold),
        color: color(0x78E1BD),
        alignment: .center
    )

    drawText(
        step.title,
        in: rectFromTop(x: x + 56, y: y + 13, width: 295, height: 22),
        font: .systemFont(ofSize: 14, weight: .semibold),
        color: color(0xF7F8FA)
    )
    drawText(
        step.japanese,
        in: rectFromTop(x: x + 56, y: y + 37, width: 295, height: 27),
        font: .systemFont(ofSize: 11, weight: .medium),
        color: color(0xD6DAE2)
    )
    drawText(
        step.english,
        in: rectFromTop(x: x + 56, y: y + 65, width: 295, height: 24),
        font: .systemFont(ofSize: 10, weight: .regular),
        color: color(0xAEB6C4)
    )
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-dmg-background.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasWidth,
    pixelsHigh: canvasHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not create bitmap.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create graphics context.\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context
context.imageInterpolation = .high

let fullRect = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
NSGradient(starting: color(0x1B1F27), ending: color(0x242A34))?.draw(in: fullRect, angle: -90)

let glow = NSBezierPath(ovalIn: NSRect(x: 135, y: 305, width: 530, height: 250))
color(0x65D6B0, alpha: 0.035).setFill()
glow.fill()

drawText(
    "AI Usage を Applications へドラッグ",
    in: rectFromTop(x: 40, y: 19, width: 720, height: 28),
    font: .systemFont(ofSize: 20, weight: .bold),
    color: color(0xF7F8FA),
    alignment: .center
)
drawText(
    "Drag AI Usage to Applications",
    in: rectFromTop(x: 40, y: 49, width: 720, height: 22),
    font: .systemFont(ofSize: 13.5, weight: .medium),
    color: color(0xAEB6C4),
    alignment: .center
)
drawArrow()

let separator = NSBezierPath()
separator.move(to: NSPoint(x: 24, y: 280))
separator.line(to: NSPoint(x: 776, y: 280))
separator.lineWidth = 1
color(0xFFFFFF, alpha: 0.10).setStroke()
separator.stroke()

drawText(
    "初回起動後  /  After launch",
    in: rectFromTop(x: 24, y: 226, width: 752, height: 24),
    font: .systemFont(ofSize: 15, weight: .semibold),
    color: color(0xF1F3F6)
)

private let steps = [
    Step(
        number: "1",
        title: "準備  /  Prepare",
        japanese: "Claude Codeへログイン。Codex・Grokは一度使う",
        english: "Sign in to Claude Code; use Codex and Grok once."
    ),
    Step(
        number: "2",
        title: "自動確認  /  Automatic",
        japanese: "AIツールを自動検出。継続利用はKeychainで「常に許可」",
        english: "AI tools are detected. Choose Always Allow for ongoing access."
    ),
    Step(
        number: "3",
        title: "言語と表示  /  Customize",
        japanese: "設定で言語・表示を選び、カードをドラッグして並べ替え",
        english: "Choose language and visibility; drag cards to reorder."
    ),
    Step(
        number: "4",
        title: "ウィジェット  /  Widget",
        japanese: "「ウィジェットを編集」から追加。本体を起動しておく",
        english: "Add from Edit Widgets; keep AI Usage running."
    ),
]

drawStep(steps[0], x: 24, y: 260)
drawStep(steps[1], x: 408, y: 260)
drawStep(steps[2], x: 24, y: 366)
drawStep(steps[3], x: 408, y: 366)

drawText(
    "詳しい対処はアプリのヘルプから  /  More troubleshooting is available in Help.",
    in: rectFromTop(x: 24, y: 470, width: 752, height: 18),
    font: .systemFont(ofSize: 10.5, weight: .regular),
    color: color(0x8E98A8),
    alignment: .center
)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode PNG.\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
