import SwiftUI

struct StaleHelpView: View {
    @ObservedObject var model: UsageModel

    private var language: AppLanguage { model.language }

    private var selectedAgent: AgentUsage? {
        guard let id = model.helpAgentID else { return nil }
        return model.allAgents.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(
                    L10n.text("help.title", language: language),
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.title2.weight(.semibold))

                Text(L10n.text("help.intro", language: language))
                Text(L10n.text("help.warning", language: language))
                    .foregroundStyle(.secondary)

                if let agent = selectedAgent {
                    observationDetails(for: agent)
                }

                Divider()

                Text(L10n.text("help.steps", language: language))
                    .font(.headline)

                if let agent = selectedAgent {
                    agentHelp(for: agent.id)
                } else {
                    agentHelp(for: "claude-code")
                    agentHelp(for: "codex")
                    agentHelp(for: "grok")
                }

                Text(L10n.text("help.widget.body", language: language))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lock.shield")
                    Text(L10n.text("help.privacy", language: language))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Button {
                        model.refresh(force: true)
                    } label: {
                        Label(
                            L10n.text("common.checkAgain", language: language),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(model.isRefreshing)

                    Text(L10n.text("help.checkAgain.detail", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .frame(width: 500, height: 560)
        .environment(\.locale, language.locale)
    }

    @ViewBuilder
    private func observationDetails(for agent: AgentUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = L10n.agentNote(agent.note, language: language) {
                Text(
                    L10n.format(
                        "help.collectionNote.format",
                        language: language,
                        note
                    )
                )
                .fontWeight(.medium)
            }
            if let observedAt = agent.observedAt {
                Text(
                    L10n.format(
                        "help.observed.format",
                        language: language,
                        format(observedAt)
                    )
                )
            }
            if model.snapshot.updatedAt != .distantPast {
                Text(
                    L10n.format(
                        "help.lastChecked.format",
                        language: language,
                        format(model.snapshot.updatedAt)
                    )
                )
            }
            Text(L10n.text("help.checkedExplanation", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func agentHelp(for id: String) -> some View {
        let keys = helpKeys(for: id)
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(keys.title, language: language))
                .font(.subheadline.weight(.semibold))
            Text(L10n.text(keys.body, language: language))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func helpKeys(for id: String) -> (title: String, body: String) {
        switch id {
        case "codex": return ("help.codex.title", "help.codex.body")
        case "grok": return ("help.grok.title", "help.grok.body")
        default: return ("help.claude.title", "help.claude.body")
        }
    }

    private func format(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .standard)
                .locale(language.locale)
        )
    }
}
