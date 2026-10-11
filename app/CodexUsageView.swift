import SwiftUI
import AppKit

// Codex card on the dashboard: one ring per usage window.
struct CodexUsageView: View {
    @ObservedObject var manager: CodexUsageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProviderHeader(name: "Codex", color: Brand.codex, detail: manager.snapshot?.accountLabel)

            if let error = manager.errorMessage {
                WarningNote(text: error)
            }

            if let snapshot = manager.snapshot {
                ForEach(snapshot.buckets) { bucket in
                    if snapshot.buckets.count > 1 || bucket.name.lowercased() != "codex" {
                        Text(bucket.name.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundColor(Color.secondaryText)
                    }
                    ForEach(bucket.displayWindows) { entry in
                        meter(entry.window, fallback: entry.id == "primary" ? "Primary" : "Secondary")
                    }
                }
            } else if manager.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Codex…").font(.caption)
                }
            } else if manager.errorMessage == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sign in with codex login to see Codex limits.")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Codex") {
                        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!)
                    }
                    .prominentButton(tint: Brand.codex)
                    .controlSize(.small)
                }
            }
        }
        .glassCard()
    }

    private func meter(_ value: CodexWindow, fallback: String) -> some View {
        let mins = value.windowDurationMins
        let fraction = value.usedPercent / 100
        return MeterRow(
            title: mins == 300 ? "Session" : mins == 10080 ? "Weekly" : fallback,
            subtitle: mins == 300 ? "5h" : mins == 10080 ? "7d" : mins.map { durationLabel($0) },
            percent: Int(value.usedPercent.rounded()),
            fraction: fraction,
            color: meterColor(fraction, base: Brand.codex),
            footnote: value.resetsAt.map { resetDescription($0) })
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

// Codex connection controls on the Settings page.
struct CodexAccountSettings: View {
    @ObservedObject var manager: CodexUsageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: manager.snapshot != nil ? "checkmark.circle.fill" : "terminal")
                    .font(.system(size: 14))
                    .foregroundColor(manager.snapshot != nil ? .green : Color.secondaryText)
                Text(manager.snapshot?.accountLabel.map { "Signed in as \($0)" }
                     ?? "Uses your Codex CLI sign-in (codex login).")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button("Open Codex") {
                    NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!)
                }
                Button("Choose Codex Executable…") {
                    let picker = NSOpenPanel()
                    picker.title = "Choose the Codex CLI executable"
                    picker.canChooseFiles = true
                    picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = false
                    if picker.runModal() == .OK, let url = picker.url {
                        guard FileManager.default.isExecutableFile(atPath: url.path) else {
                            manager.errorMessage = "Choose the executable named codex, rather than an app folder."
                            return
                        }
                        UserDefaults.standard.set(url.path, forKey: "codex_executable")
                        manager.fetchUsage()
                    }
                }
            }
            .secondaryButton()
            .controlSize(.small)
        }
    }
}
