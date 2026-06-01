import Combine
import Foundation
import SwiftUI

// MARK: - Supported languages

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    /// The .lproj resource code to load, or nil to follow the system language.
    var resourceCode: String? {
        self == .system ? nil : rawValue
    }

    /// Locale that drives SwiftUI `Text` localization and number/date formatting.
    /// `.system` resolves to a concrete locale (the app's effective system
    /// language) rather than `.autoupdatingCurrent`, which SwiftUI does not
    /// reliably use to re-pick the localization when switching back to it.
    var locale: Locale {
        switch self {
        case .system:  return Locale(identifier: AppLanguage.systemLanguageCode)
        case .english, .chinese: return Locale(identifier: rawValue)
        }
    }

    /// The language code the app would use when following the system setting.
    static var systemLanguageCode: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }
}

// MARK: - Language manager

/// Holds the user's language choice and exposes the matching locale + bundle.
/// SwiftUI `Text` follows `locale` (set via `.environment(\.locale,)`); plain
/// `String(localized:)` call sites must pass `bundle` explicitly.
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    private static let key = "loopRecording.appLanguage"

    @Published var current: AppLanguage {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: Self.key) }
    }

    var locale: Locale { current.locale }

    /// The bundle to resolve `String(localized:)` against. Falls back to `.main`
    /// (system resolution) when following the system language.
    var bundle: Bundle {
        let code = current.resourceCode ?? AppLanguage.systemLanguageCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            return languageBundle
        }
        return .main
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        current = saved.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
}
