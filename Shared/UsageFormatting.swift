import AppKit
import SwiftUI

extension UsageWindow {
    var severity: UsageSeverity { UsageSeverity.of(usedPercent) }
    var tint: Color { severity.color }

    /// API values use the 0...100 scale, while Foundation's percent style expects 0...1.
    /// FormatStyle follows the user's locale (including percent-sign placement and digits).
    private var usedFraction: Double { min(max(usedPercent, 0), 100) / 100 }
    private var remainingFraction: Double { min(max(remainingPercent, 0), 100) / 100 }

    var usedText: String {
        usedFraction.formatted(.percent.precision(.fractionLength(0)))
    }

    var remainingValueText: String {
        remainingFraction.formatted(.percent.precision(.fractionLength(0)))
    }

    var remainingText: String { "\(remainingValueText) left" }
}

extension AgentUsage {
    /// エージェントの識別色。バーの色は逼迫度を表すので、識別はドットで行う。
    var accent: Color {
        switch id {
        case "claude-code": return Color(red: 0.85, green: 0.47, blue: 0.28)
        case "codex": return Color(red: 139 / 255, green: 124 / 255, blue: 246 / 255)
        case "grok": return grokAccent
        case "gemini": return Color(red: 0.36, green: 0.62, blue: 0.98)
        case "cursor": return Color(red: 0.72, green: 0.52, blue: 0.96)
        default: return .gray
        }
    }

    /// Grokはモノクロ系のcool gray。ライト面では濃く、ダーク面では明るくして識別性を保つ。
    private var grokAccent: Color {
        Color(nsColor: NSColor(name: NSColor.Name("AIUsage.GrokAccent")) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 170 / 255, green: 181 / 255, blue: 194 / 255, alpha: 1)
                : NSColor(srgbRed: 86 / 255, green: 99 / 255, blue: 114 / 255, alpha: 1)
        })
    }
}

extension AgentStatus {
    var isActionable: Bool { self == .ok || self == .stale }
}
