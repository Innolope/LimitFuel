import SwiftUI
import AppKit

struct CodexUsageView: View {
    @ObservedObject var manager: CodexUsageManager
    @Binding var notificationsEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex Usage").font(.headline)
            if manager.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Checking Codex…").font(.caption) }
            }
            if let error = manager.errorMessage {
                Text(error).font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = manager.snapshot {
                if let account = snapshot.accountLabel {
                    Text(account).font(.caption).foregroundColor(Color.secondaryText).lineLimit(2)
                }
                ForEach(snapshot.buckets) { bucket in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(bucket.name == "codex" ? "Codex" : bucket.name).font(.subheadline).fontWeight(.semibold)
                        window(bucket.primary, fallback: "Primary window")
                        window(bucket.secondary, fallback: "Secondary window")
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
            } else if manager.errorMessage == nil && !manager.isLoading {
                Text("Connect your existing Codex sign-in to see usage limits.")
                    .font(.caption).foregroundColor(Color.secondaryText)
            }
            HStack {
                if let updated = manager.lastUpdated, manager.snapshot != nil {
                    Text("Updated \(updated, style: .time)").font(.caption2).foregroundColor(Color.secondaryText)
                }
                Spacer()
                Button("Refresh") { manager.fetchUsage() }.disabled(manager.isLoading)
            }
            HStack {
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
            .controlSize(.small)
            Toggle("Usage notifications", isOn: $notificationsEnabled).font(.caption)
            Text("Uses your existing Codex sign-in. Install Codex CLI and run codex login with ChatGPT if needed. Refreshes every minute, or every 12 seconds when five-hour usage is above 90%, until it resets.")
                .font(.caption2).foregroundColor(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func window(_ value: CodexWindow?, fallback: String) -> some View {
        if let value = value {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(value.windowDurationMins.map { durationLabel($0) } ?? fallback).font(.caption)
                    Spacer()
                    Text(String(format: "%.0f%% used", value.usedPercent)).font(.caption).fontWeight(.medium)
                }
                UsageBar(value: value.usedPercent / 100, color: value.usedPercent > 90 ? .red : value.usedPercent >= 70 ? .orange : .green)
                if let reset = value.resetsAt {
                    Text("Resets \(reset, style: .relative)").font(.caption2).foregroundColor(Color.secondaryText)
                } else {
                    Text("Reset time unavailable").font(.caption2).foregroundColor(Color.secondaryText)
                }
            }
        } else {
            Text("\(fallback): unavailable").font(.caption2).foregroundColor(Color.secondaryText)
        }
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }
}
