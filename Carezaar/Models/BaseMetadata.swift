import Foundation

/// Per-item localisation. The parent foreign key varies by table
/// (`carecondition_id`, `careday_id`, …) and is not needed for display, so only the
/// shared fields are decoded.
struct Translation: Codable, Hashable, Sendable {
    let id: Int
    let languageId: Int
    let name: String

    private enum CodingKeys: String, CodingKey {
        case id, name
        case languageId = "language_id"
    }
}

/// Shape shared by every translated lookup table: careconditions, caredays,
/// carespecials, certifications, clienttypes, commutes, contents, countries,
/// experiences, genders, issuetypes, languageskills, reasons, roles, shifts,
/// subjects, worktypes.
struct BaseItem: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let code: String?
    let icon: String?
    /// `base/contents` identifies rows by `slug` rather than `code`; every other
    /// table leaves this nil.
    let slug: String?
    let translations: [Translation]

    private enum CodingKeys: String, CodingKey { case id, code, icon, slug, translations }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        translations = try c.decodeIfPresent([Translation].self, forKey: .translations) ?? []
    }

    /// Localised label, falling back to the default language then to `code`.
    func name(languageId: Int, fallbackLanguageId: Int = 1) -> String {
        translations.first { $0.languageId == languageId }?.name
            ?? translations.first { $0.languageId == fallbackLanguageId }?.name
            ?? translations.first?.name
            ?? code
            ?? ""
    }
}

struct Language: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let code: String
    let name: String
    let icon: String?
    let isDefault: Bool
    let isRtl: Bool

    private enum CodingKeys: String, CodingKey {
        case id, code, name, icon
        case isDefault = "is_default"
        case isRtl = "is_rtl"
    }
}

struct City: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let stateId: Int

    private enum CodingKeys: String, CodingKey {
        case id, name
        case stateId = "state_id"
    }
}

struct USState: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let countryId: Int
    let slug: String?
    let translations: [Translation]

    private enum CodingKeys: String, CodingKey {
        case id, slug, translations
        case countryId = "country_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        countryId = try c.decode(Int.self, forKey: .countryId)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        translations = try c.decodeIfPresent([Translation].self, forKey: .translations) ?? []
    }

    func name(languageId: Int) -> String {
        translations.first { $0.languageId == languageId }?.name
            ?? translations.first?.name ?? slug ?? ""
    }
}

struct Faq: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let faqCategoryId: Int?
    let translations: [FaqTranslation]

    private enum CodingKeys: String, CodingKey {
        case id, translations
        case faqCategoryId = "faq_category_id"
    }
}

struct FaqTranslation: Codable, Hashable, Sendable {
    let id: Int
    let languageId: Int
    let question: String?
    let answer: String?

    private enum CodingKeys: String, CodingKey {
        case id, question, answer
        case languageId = "language_id"
    }
}

/// `GET base/info` — per-table cache timestamps used to decide what to refetch.
struct BaseInfo: Codable, Hashable, Sendable {
    let tsCache: Int
    let total: Int
    let careconditions: Int
    let caredays: Int
    let carespecials: Int
    let certifications: Int
    let cities: Int
    let clienttypes: Int
    let commutes: Int
    let contents: Int
    let countries: Int
    let experiences: Int
    let faqCategories: Int
    let faqs: Int
    let genders: Int
    let issuetypes: Int
    let languages: Int
    let languageskills: Int
    let media: Int
    let roles: Int
    let shifts: Int
    let states: Int
    let subjects: Int
    let worktypes: Int

    private enum CodingKeys: String, CodingKey {
        case total, careconditions, caredays, carespecials, certifications, cities,
             clienttypes, commutes, contents, countries, experiences, faqs, genders,
             issuetypes, languages, languageskills, media, roles, shifts, states,
             subjects, worktypes
        case tsCache = "ts_cache"
        case faqCategories = "faq_categories"
    }
}

/// FAQ categories translate into `title`, unlike the other tables' `name`.
struct FaqCategory: Codable, Identifiable, Hashable, Sendable {
    struct Translation: Codable, Hashable, Sendable {
        let id: Int
        let languageId: Int
        let title: String
        private enum CodingKeys: String, CodingKey { case id, title; case languageId = "language_id" }
    }
    let id: Int
    let slug: String?
    let translations: [Translation]

    func title(languageId: Int) -> String {
        translations.first { $0.languageId == languageId }?.title ?? translations.first?.title ?? slug ?? ""
    }
}
