import Foundation

/// The language Apple Speech recognizes (conversation mode, dictation mode, Apple Speech panel).
/// Switched with Fn+⌃⌥L or the menu bar; stored in UserDefaults under `speechLanguage`.
enum SpeechLanguage: String {
    case english = "en-US"
    case german = "de-DE"

    static let defaultsKey = "speechLanguage"
    /// Posted on the main thread after the language changes.
    static let didChange = Notification.Name("SpeechLanguageDidChange")

    static var current: SpeechLanguage {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SpeechLanguage.init) ?? .english
    }

    /// Switches English ↔ German and announces the change.
    static func toggle() {
        let next: SpeechLanguage = current == .english ? .german : .english
        UserDefaults.standard.set(next.rawValue, forKey: defaultsKey)
        print("🌐 Speech language: \(next.name) (\(next.rawValue))")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    var locale: Locale { Locale(identifier: rawValue) }
    var name: String { self == .english ? "English" : "Deutsch" }
}
