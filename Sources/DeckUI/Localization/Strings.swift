import Foundation

public func tr(_ key: StaticString, _ arguments: String...) -> String {
    Strings.resolve(key.description, arguments, in: Strings.override ?? Strings.bundle)
}

enum Strings {
    static let bundle = Bundle.module

    nonisolated(unsafe) static var override: Bundle?

    static func resolve(_ key: String, _ arguments: [String], in bundle: Bundle) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments.map { $0 as NSString })
    }

    static var language: String {
        if let override { return URL(filePath: override.bundlePath).deletingPathExtension().lastPathComponent }
        return bundle.preferredLocalizations.first ?? "en"
    }

    static var wordsLocale: Locale { locale(language: language) }

    static func locale(language: String, base: Locale = .current) -> Locale {
        var components = Locale.Components(locale: base)
        components.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: components)
    }

    static func bundle(language: String) -> Bundle? {
        bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}
