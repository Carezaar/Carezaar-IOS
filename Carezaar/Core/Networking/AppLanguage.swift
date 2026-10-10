import Foundation

/// The backend localises every response from the `Accept-Language` header and
/// **rejects `*` with a 500** (`Invalid "*" locale.`), so a concrete locale must be
/// sent on every request. The Android client does this in an OkHttp interceptor
/// using the language the user picked on `ChangeLanguage`.
@MainActor
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()

    private let defaultsKey = "carezaar.languageCode"
    private let idKey = "carezaar.languageId"

    /// Language code sent as `Accept-Language`, e.g. `en`.
    @Published var code: String {
        didSet { UserDefaults.standard.set(code, forKey: defaultsKey) }
    }

    /// `Language.id`, needed to pick the right `translations` entry for labels.
    @Published var id: Int {
        didSet { UserDefaults.standard.set(id, forKey: idKey) }
    }

    private init() {
        code = UserDefaults.standard.string(forKey: defaultsKey) ?? "en"
        let stored = UserDefaults.standard.integer(forKey: idKey)
        id = stored == 0 ? 1 : stored
    }

    func select(_ language: Language) {
        code = language.code
        id = language.id
    }

    var isEnglish: Bool { id == 1 }

    /// Non-isolated snapshot for the networking layer, which runs off the main actor.
    nonisolated static var currentCode: String {
        UserDefaults.standard.string(forKey: "carezaar.languageCode") ?? "en"
    }
}
