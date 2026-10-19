import Foundation

/// One complete, versioned reference snapshot. No screen observes a partial refresh.
@MainActor
final class BaseDataStore: ObservableObject {
    @Published private(set) var tables: [BaseTable: [BaseItem]] = [:]
    @Published private(set) var languages: [Language] = []
    @Published private(set) var states: [USState] = []
    @Published private(set) var faqs: [Faq] = []
    @Published private(set) var faqCategories: [FaqCategory] = []
    @Published private(set) var media: [BaseMedia] = []
    @Published private(set) var isReady = false
    @Published private(set) var failed = false
    let localization = Localization()

    private let service: BaseService
    private let cacheURL: URL
    private var snapshot: Cache?
    private var bootstrapTask: Task<Void, Never>?

    init(service: BaseService = BaseService(), cacheURL: URL? = nil) {
        self.service = service
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("carezaar-base.json")
        if let data = try? Data(contentsOf: self.cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.isComplete {
            apply(cache)
        }
    }

    func items(_ table: BaseTable) -> [BaseItem] { tables[table] ?? [] }
    func name(_ table: BaseTable, id: Int, languageId: Int) -> String {
        items(table).first { $0.id == id }?.name(languageId: languageId) ?? ""
    }

    func bootstrap(force: Bool = false) async {
        if let running = bootstrapTask { return await running.value }
        let task = Task { await runBootstrap(force: force) }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    private func runBootstrap(force: Bool) async {
        failed = false
        let cached = snapshot?.isComplete == true
        // A complete disk snapshot is safe offline; an incomplete legacy cache is not.
        isReady = cached
        let info = try? await service.info()
        #if DEBUG
        QARequestLedger.shared.recordReferenceCompletion(decoded: info != nil, cached: cached,
            markerMatches: cached && info?.tsCache == snapshot?.tsCache)
        #endif
        if cached, !force, info == nil || info?.tsCache == snapshot?.tsCache { return }
        // Without the server marker/counts a first download cannot establish a
        // versioned complete snapshot. A previously validated cache remains usable.
        guard let info else { failed = !cached; return }

        var pending = BaseTable.allCases.map(Request.table)
        pending += [.languages, .states, .media, .faqs, .faqCategories]
        var staged = Cache(info: info)
        var complete = true
        await withTaskGroup(of: Loaded?.self) { group in
            var queue = pending[...]
            func next() {
                guard let request = queue.popFirst() else { return }
                group.addTask { [service] in
                    // A changed global marker authorizes a fresh complete snapshot.
                    // ts_cache=0 prevents unchanged tables becoming empty partial deltas.
                    switch request {
                    case .table(let table): return try? .table(table, await service.items(table))
                    case .languages: return try? .languages(await service.languages())
                    case .states: return try? .states(await service.states())
                    case .media: return try? .media(await service.media())
                    case .faqs: return try? .faqs(await service.faqs())
                    case .faqCategories: return try? .faqCategories(await service.faqCategories())
                    }
                }
            }
            for _ in 0..<min(6, pending.count) { next() }
            for await result in group {
                switch result {
                case .table(let table, let list): staged.tables[table.rawValue] = list
                case .languages(let list): staged.languages = list
                case .states(let list): staged.states = list
                case .media(let list): staged.media = list
                case .faqs(let list): staged.faqs = list
                case .faqCategories(let list): staged.faqCategories = list
                case nil: complete = false
                }
                next()
            }
        }
        guard complete, staged.isComplete else {
            // Keep all previous tables and their marker together, including on disk.
            failed = !cached
            return
        }
        apply(staged)
        isReady = true
        if let data = try? JSONEncoder().encode(staged) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func apply(_ cache: Cache) {
        snapshot = cache
        tables = Dictionary(uniqueKeysWithValues: cache.tables.compactMap { key, value in
            BaseTable(rawValue: key).map { ($0, value) }
        })
        languages = cache.languages
        states = cache.states
        media = cache.media
        faqs = cache.faqs
        faqCategories = cache.faqCategories
        localization.apply(tables[.contents] ?? [])
    }

    private enum Request: Sendable {
        case table(BaseTable), languages, states, media, faqs, faqCategories
    }
    private enum Loaded: Sendable {
        case table(BaseTable, [BaseItem]), languages([Language]), states([USState])
        case media([BaseMedia]), faqs([Faq]), faqCategories([FaqCategory])
    }
    private struct Cache: Codable {
        let schemaVersion: Int
        var tsCache: Int
        /// Verified `base/info` integers are complete-list row counts. Persist
        /// these with the lists so decoded-but-truncated disk caches are rejected.
        let expectedCounts: [String: Int]
        var tables: [String: [BaseItem]] = [:]
        var languages: [Language] = []
        var states: [USState] = []
        var media: [BaseMedia] = []
        var faqs: [Faq] = []
        var faqCategories: [FaqCategory] = []
        init(info: BaseInfo) {
            schemaVersion = 3
            tsCache = info.tsCache
            expectedCounts = [
                "careconditions": info.careconditions, "caredays": info.caredays,
                "carespecials": info.carespecials, "certifications": info.certifications,
                "clienttypes": info.clienttypes, "commutes": info.commutes,
                "contents": info.contents, "countries": info.countries,
                "experiences": info.experiences, "genders": info.genders,
                "issuetypes": info.issuetypes, "languageskills": info.languageskills,
                "roles": info.roles, "shifts": info.shifts, "subjects": info.subjects,
                "worktypes": info.worktypes, "languages": info.languages,
                "states": info.states, "media": info.media, "faqs": info.faqs,
                "faq_categories": info.faqCategories
            ]
        }
        var isComplete: Bool {
            let advertisedDatasets = Set(BaseTable.allCases.filter { $0 != .reasons }.map(\.rawValue)
                + ["languages", "states", "media", "faqs", "faq_categories"])
            guard schemaVersion == 3, tsCache >= 0, !languages.isEmpty,
                  !(tables[BaseTable.contents.rawValue] ?? []).isEmpty,
                  Set(expectedCounts.keys) == advertisedDatasets, expectedCounts.values.allSatisfy({ $0 >= 0 })
            else { return false }
            for table in BaseTable.allCases {
                guard let list = tables[table.rawValue], Set(list.map(\.id)).count == list.count else { return false }
                // `reasons` has no advertised count. Require a successfully loaded
                // unique list, but do not invent a positive count or reject valid empty data.
                if table != .reasons, expectedCounts[table.rawValue] != list.count { return false }
            }
            return matches(languages.map(\.id), "languages")
                && matches(states.map(\.id), "states")
                && matches(media.map(\.id), "media")
                && matches(faqs.map(\.id), "faqs")
                && matches(faqCategories.map(\.id), "faq_categories")
        }
        private func matches(_ ids: [Int], _ dataset: String) -> Bool {
            expectedCounts[dataset] == ids.count && Set(ids).count == ids.count
        }
    }
}
