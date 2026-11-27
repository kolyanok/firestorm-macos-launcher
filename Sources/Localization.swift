import Foundation

enum LauncherLocalization {
    static func resolvedLanguage(preference: String?, preferredLanguages: [String]) -> String {
        if preference == "ru" || preference == "en" { return preference! }
        return preferredLanguages.first?.lowercased().hasPrefix("ru") == true ? "ru" : "en"
    }

    static var language: String {
        resolvedLanguage(preference: UserDefaults.standard.string(forKey: "LauncherLanguage"),
                         preferredLanguages: Locale.preferredLanguages)
    }

    static let russian = InterfaceTranslations.russian.merging(CoreTranslations.russian) { first, _ in first }

    static func text(_ english: String, language: String) -> String {
        language == "ru" ? russian[english] ?? english : english
    }
}

func L(_ english: String) -> String {
    LauncherLocalization.text(english, language: LauncherLocalization.language)
}

func LF(_ english: String, _ arguments: CVarArg...) -> String {
    String(format: L(english), locale: Locale(identifier: LauncherLocalization.language), arguments: arguments)
}
