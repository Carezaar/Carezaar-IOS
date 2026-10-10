import SwiftUI

/// Server-driven UI copy.
///
/// Carezaar does not ship a static string catalogue: every label comes from
/// `GET base/contents`, keyed by slug and translated per language. This resolves a
/// slug for the currently selected language, falling back to English and then to the
/// slug itself so a missing entry is visible rather than blank.
///
/// It also carries a reverse index (English text → slug) so the Figma-rendered
/// screens, whose scene JSON has English baked into the text nodes, can be localised
/// without re-authoring the designs.
@MainActor
final class Localization: ObservableObject {
    static let englishLanguageId = 1

    @Published private(set) var contents: [BaseItem] = []
    /// Current `Language.id`, kept in sync by the app root.
    @Published var languageId: Int = AppLanguageDefaults.id

    private var bySlug: [String: BaseItem] = [:]
    private var slugByEnglish: [String: String] = [:]

    func apply(_ contents: [BaseItem]) {
        self.contents = contents
        bySlug = Dictionary(contents.compactMap { item in item.slug.map { ($0, item) } },
                            uniquingKeysWith: { first, _ in first })
        var reverse: [String: String] = [:]
        for content in contents {
            guard let slug = content.slug,
                  let english = content.translations
                    .first(where: { $0.languageId == Self.englishLanguageId })?.name else { continue }
            let key = Self.normalise(english)
            // First slug wins: several slugs share copy like "Continue".
            if reverse[key] == nil { reverse[key] = slug }
        }
        slugByEnglish = reverse
    }

    /// Server content rows known to hold the wrong language. Applied only while the
    /// server still returns exactly the bad text, so a CMS fix takes over by itself.
    private static let contentFixes: [(slug: String, languageId: Int, bad: String, good: String)] = [
        ("signup_credentials_confirm_password_placeholder", 3, "Confirmez votre mot de passe...", "أكد كلمة المرور الخاصة بك..."),
        ("signup_setup_password_confirm_password_placeholder", 3, "Confirmez votre mot de passe...", "أكد كلمة المرور الخاصة بك..."),
    ]

    private func corrected(_ slug: String, _ languageId: Int, _ text: String?) -> String? {
        Self.contentFixes.first { $0.slug == slug && $0.languageId == languageId && $0.bad == text }?.good ?? text
    }

    /// Translated copy for a slug.
    func callAsFunction(_ slug: String, languageId: Int) -> String {
        guard let content = bySlug[slug] else { return slug }
        return corrected(slug, languageId, content.translations.first { $0.languageId == languageId }?.name)
            ?? content.translations.first { $0.languageId == Self.englishLanguageId }?.name
            ?? slug
    }

    var isLoaded: Bool { !bySlug.isEmpty }

    /// Copy for a slug in the current language, else English, else `fallback`.
    func t(_ slug: String, _ fallback: String = "") -> String {
        guard let content = bySlug[slug] else { return fallback.isEmpty ? slug : fallback }
        let name = corrected(slug, languageId, content.translations.first { $0.languageId == languageId }?.name)
            ?? content.translations.first { $0.languageId == Self.englishLanguageId }?.name
        return (name?.isEmpty == false ? name : nil) ?? (fallback.isEmpty ? slug : fallback)
    }

    /// Localised label of a lookup-table row.
    func label(_ item: BaseItem?) -> String {
        item?.name(languageId: languageId) ?? ""
    }

    /// Translation for a piece of English copy baked into a Figma scene, or nil when
    /// the string is not a known content entry (logos, punctuation, numerals).
    func translating(english: String, languageId: Int) -> String? {
        guard languageId != Self.englishLanguageId else { return nil }
        guard let slug = slugByEnglish[Self.normalise(english)] else { return nil }
        let translated = self(slug, languageId: languageId)
        return translated == slug ? nil : translated
    }

    /// Figma text nodes carry line separators and padding that the API copy does not.
    private static func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Design copy and server copy differ only in closing punctuation in places.
            .replacingOccurrences(of: #"[.…!:]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}

/// Non-isolated read of the persisted language id (the `-carezaar.languageId` default).
enum AppLanguageDefaults {
    static var id: Int {
        let stored = UserDefaults.standard.integer(forKey: "carezaar.languageId")
        return stored == 0 ? 1 : stored
    }
}
