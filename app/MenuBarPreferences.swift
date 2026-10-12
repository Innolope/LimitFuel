import Foundation
import Combine

enum MenuBarPercentageMode: String {
    case used, remaining

    // The menu bar and the popup meters share these, so both show one number.
    func displayedPercent(used: Double) -> Int {
        Int(displayedValue(used: used).rounded(.toNearestOrAwayFromZero))
    }

    func displayedFraction(used: Double) -> Double {
        displayedValue(used: used) / 100
    }

    func accessibilityValue(used: Double) -> String {
        "\(displayedPercent(used: used)) percent \(rawValue)"
    }

    private func displayedValue(used: Double) -> Double {
        let clamped = used.isFinite ? max(0, min(100, used)) : 0
        return self == .remaining ? 100 - clamped : clamped
    }
}

struct MenuBarWindowOption: Identifiable, Equatable {
    let id: String
    let provider: MenuBarProvider
    let label: String
    let percent: Double
    let durationMinutes: Int?
    let isPreferredBucket: Bool
    var resetsAt: Date? = nil
}

enum MenuBarSelection {
    static let automaticID = "automatic"

    static func selectedOption(provider: MenuBarProvider, options: [MenuBarWindowOption],
                               selectionID: String?) -> MenuBarWindowOption? {
        let valid = options.filter { $0.provider == provider && $0.percent.isFinite && (0...100).contains($0.percent) }
        if let id = selectionID, id != automaticID, let selected = valid.first(where: { $0.id == id }) {
            return selected
        }
        let sessions = valid.filter { option in
            guard let minutes = option.durationMinutes else { return false }
            return minutes > 0 && minutes < 1440
        }
        let candidates = sessions.isEmpty ? valid : sessions
        return candidates.first(where: { $0.isPreferredBucket }) ?? candidates.first
    }

    // Settings lists real windows only and shows the one the menu bar is using.
    // Showing a fallback never rewrites a saved choice that is temporarily missing.
    static func pickerOptions(provider: MenuBarProvider, options: [MenuBarWindowOption]) -> [MenuBarWindowOption] {
        options.filter { $0.provider == provider && $0.percent.isFinite && (0...100).contains($0.percent) }
    }

    static func pickerSelectionID(provider: MenuBarProvider, options: [MenuBarWindowOption],
                                  selectionID: String?) -> String? {
        selectedOption(provider: provider, options: options, selectionID: selectionID)?.id
    }
}

final class MenuBarPreferences: ObservableObject {
    @Published private var selections: [MenuBarProvider: String]
    @Published private(set) var percentageMode: MenuBarPercentageMode
    private let defaults: UserDefaults
    // Called after the new preference is available; observing objectWillChange
    // would read the old value when immediately redrawing the status item.
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        percentageMode = (defaults.object(forKey: "menubar_percentage_mode") as? String)
            .flatMap(MenuBarPercentageMode.init(rawValue:)) ?? .remaining
        selections = Dictionary(uniqueKeysWithValues: [MenuBarProvider.claude, .codex].map { provider in
            (provider, Self.normalized(defaults.object(forKey: Self.key(provider)) as? String))
        })
    }

    func setPercentageMode(_ mode: MenuBarPercentageMode) {
        defaults.set(mode.rawValue, forKey: "menubar_percentage_mode")
        guard percentageMode != mode else { return }
        percentageMode = mode
        onChange?()
    }

    func selectionID(for provider: MenuBarProvider) -> String {
        selections[provider] ?? MenuBarSelection.automaticID
    }

    func select(_ id: String, for provider: MenuBarProvider) {
        let normalized = Self.normalized(id)
        defaults.set(normalized, forKey: Self.key(provider))
        guard selections[provider] != normalized else { return }
        selections[provider] = normalized
        onChange?()
    }

    private static func key(_ provider: MenuBarProvider) -> String {
        "menubar_\(provider.rawValue)_window"
    }

    private static func normalized(_ id: String?) -> String {
        guard let id = id, !id.isEmpty, id.utf8.count <= 4096,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return MenuBarSelection.automaticID
        }
        return id
    }
}
