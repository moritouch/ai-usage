import AppIntents
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let language: AppLanguage
    /// 「ウィジェットを編集」で選ばれたエージェント。空なら本体の並び順に従う。
    let selectedIDs: [String]
}

struct UsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(
            date: Date(), snapshot: .sample,
            language: LanguagePreference.load(), selectedIDs: []
        )
    }

    func snapshot(for configuration: SelectAgentsIntent,
                  in context: Context) async -> UsageEntry {
        return UsageEntry(
            date: Date(),
            // The gallery never needs personal usage values. Keep previews deterministic
            // and read the App Group only for a real widget snapshot.
            snapshot: context.isPreview ? .sample : current(),
            language: LanguagePreference.load(),
            selectedIDs: configuration.selectedIDs
        )
    }

    func timeline(for configuration: SelectAgentsIntent,
                  in context: Context) async -> Timeline<UsageEntry> {
        let entry = UsageEntry(
            date: Date(), snapshot: current(),
            language: LanguagePreference.load(),
            selectedIDs: configuration.selectedIDs
        )
        // This is a best-effort request. WidgetKit may delay it to preserve the
        // system update budget; the containing app also requests reloads on changes.
        return Timeline(entries: [entry],
                        policy: .after(Date().addingTimeInterval(10 * 60)))
    }

    /// 拡張はサンドボックス内で ~/.codex を読めない。
    /// 本体（メニューバーアプリ）が書き出した snapshot だけを読む。
    private func current() -> UsageSnapshot {
        SnapshotStore.load()
    }
}

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget { AIUsageWidget() }
}

struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "AIUsageWidget",
            intent: SelectAgentsIntent.self,
            provider: UsageProvider()
        ) { entry in
            UsageWidgetView(
                snapshot: entry.snapshot,
                language: entry.language,
                selectedIDs: entry.selectedIDs
            )
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI Usage")
        .description(LocalizedStringKey("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
