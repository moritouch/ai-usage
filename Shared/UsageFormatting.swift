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
    ///
    /// 各社の実際のブランドに合わせる。直感的に結びつくことを優先し、
    /// 見分けやすさのために存在しない色を割り当てることはしない。
    var accent: Color {
        switch id {
        case "claude-code": return Color(red: 0.85, green: 0.47, blue: 0.28)
        case "codex": return Color(red: 139 / 255, green: 124 / 255, blue: 246 / 255)
        // Grokと Grok Bot は同じxAIのブランドで、どちらもモノクロ。同じ色で扱う。
        case "grok", "grok-bot": return grokAccent
        case "gemini": return Color(red: 0.36, green: 0.62, blue: 0.98)
        case "cursor": return cursorAccent
        default: return .gray
        }
    }

    /// Grokはモノクロ系のcool gray。ライト面では濃く、ダーク面では明るくして識別性を保つ。
    /// 値は Assets.xcassets の GrokAccent（ライト 86/99/114、ダーク 170/181/194）。
    private var grokAccent: Color { Color("GrokAccent") }

    /// Cursorは完全な無彩色。公式アイコンは黒と白だけで構成されている。
    /// Grokのcool grayより暗く（ライト面）、より明るく（ダーク面）して、
    /// 同じモノクロ同士でも取り違えないようにする。
    /// 値は Assets.xcassets の CursorAccent（ライト 26/26/26、ダーク 240/240/240）。
    ///
    /// 明暗で変わる色はアセットカタログに置く。`NSColor(name:dynamicProvider:)` で作ると
    /// 名前だけあってバンドルの無い色になり、macOS 27.2以降のWidgetKitは表示内容の保存時に
    /// `WidgetArchiver.ValidationError.bundle` で拒否する。ウィジェットは仮表示のまま止まる。
    private var cursorAccent: Color { Color("CursorAccent") }
}

extension AgentStatus {
    var isActionable: Bool { self == .ok || self == .stale }
}
