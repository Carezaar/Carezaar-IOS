import Foundation

/// Local cache of the translated lookup tables.
///
/// Android persists these in a Room database and refetches a table only when
/// `base/info` reports a newer `ts_cache` than the stored copy. This reproduces that
/// strategy with an on-disk JSON cache, which is enough for the form pickers the
/// architecture doc calls for ("fetched and cached locally on app bootstrap").
@MainActor
final class BaseDataStore: ObservableObject {
    @Published private(set) var tables: [BaseTable: [BaseItem]] = [:]
    @Published private(set) var languages: [Language] = []
    @Published private(set) var states: [USState] = []
    @Published private(set) var isReady = false
    /// Nothing could be loaded and nothing is cached: the splash offers a retry.
    @Published private(set) var failed = false

    private let service: BaseService
    private let cacheURL: URL
    private var tsCache: Int = 0
    /// Server-driven UI copy, refreshed alongside the lookup tables.
    let localization = Localization()

    init(service: BaseService = BaseService()) {
        self.service = service
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheURL = dir.appendingPathComponent("carezaar-base.json")
        loadFromDisk()
    }

    func items(_ table: BaseTable) -> [BaseItem] { tables[table] ?? [] }

    /// Resolves a localised label for an id in a table — the operation every picker needs.
    func name(_ table: BaseTable, id: Int, languageId: Int) -> String {
        items(table).first { $0.id == id }?.name(languageId: languageId) ?? ""
    }

    /// Bootstrap. Refetches only when the server's cache stamp moved on.
    ///
    /// The backend is slow on these tables (BE-12: `base/contents` alone is ~900 KB and
    /// ~2 s before the first byte), so the app doesn't wait for all of them: a cached
    /// copy opens the app at once and refreshes behind it, and a first launch opens as
    /// soon as the copy and the language list arrive while the other tables fill in.
    func bootstrap(force: Bool = false) async {
        // The splash calls this from its `.task`, and the splash leaves the screen as
        // soon as the app can open; the remaining tables must keep loading after that
        // view's task is cancelled, so the work runs in a task of its own.
        if let running = bootstrapTask { return await running.value }
        let task = Task { await runBootstrap(force: force) }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    private var bootstrapTask: Task<Void, Never>?

    private func runBootstrap(force: Bool) async {
        failed = false
        let hadCache = !tables.isEmpty && !languages.isEmpty
        if hadCache && !force { isReady = true }

        async let infoCall = try? service.info()
        if hadCache && !force {
            let complete = BaseTable.allCases.allSatisfy { tables[$0] != nil } && !states.isEmpty
            if complete, let info = await infoCall, info.tsCache == tsCache { return }
        }
        let stamp = await infoCall?.tsCache

        // The server answers a few requests at a time and sometimes resets a
        // connection (BE-12), so at most six are in flight and failures are retried;
        // a table that never arrived would leave its pickers empty for the session.
        var pending: [Request] = [.table(.contents), .languages]
            + BaseTable.allCases.filter { $0 != .contents }.map(Request.table) + [.states]
        for attempt in 0..<Self.attempts where !pending.isEmpty {
            if attempt > 0 { try? await Task.sleep(for: .seconds(attempt)) }
            pending = await load(pending)
        }
        let anyFailed = !pending.isEmpty

        guard !tables.isEmpty, tables[.contents] != nil || hadCache else {
            // Offline on a first launch: nothing to show yet.
            failed = !isReady
            return
        }
        // A partial failure keeps the old stamp so the missing tables load next time.
        if !anyFailed, let stamp { tsCache = stamp }
        isReady = true
        saveToDisk()
    }

    private static let attempts = 3
    private static let maxConcurrent = 6

    private enum Request: Sendable { case table(BaseTable), languages, states }

    /// Fetches `requests`, applying each result as it lands; returns the ones that failed.
    private func load(_ requests: [Request]) async -> [Request] {
        var failed: [Request] = []
        await withTaskGroup(of: (Request, Bool, Loaded?).self) { group in
            var queue = requests[...]
            func next() {
                guard let request = queue.popFirst() else { return }
                group.addTask { [service] in
                    switch request {
                    case .table(let table):
                        let items = try? await service.items(table)
                        return (request, items != nil, items.map { .table(table, $0) })
                    case .languages:
                        let list = try? await service.languages()
                        return (request, list != nil, list.map(Loaded.languages))
                    case .states:
                        let list = try? await service.states()
                        return (request, list != nil, list.map(Loaded.states))
                    }
                }
            }
            for _ in 0..<Self.maxConcurrent { next() }
            for await (request, ok, loaded) in group {
                switch loaded {
                case .table(let table, let items):
                    tables[table] = items
                    if table == .contents { localization.apply(items) }
                case .languages(let list): languages = list
                case .states(let list): states = list
                case nil: break
                }
                if !ok { failed.append(request) }
                if !isReady, tables[.contents] != nil, !languages.isEmpty { isReady = true }
                next()
            }
        }
        return failed
    }

    private enum Loaded: Sendable {
        case table(BaseTable, [BaseItem])
        case languages([Language])
        case states([USState])
    }

    // MARK: - Persistence

    private struct Cache: Codable {
        var tsCache: Int
        var tables: [String: [BaseItem]]
        var languages: [Language]
        var states: [USState]
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        tsCache = cache.tsCache
        languages = cache.languages
        states = cache.states
        tables = Dictionary(uniqueKeysWithValues: cache.tables.compactMap { key, value in
            BaseTable(rawValue: key).map { ($0, value) }
        })
        localization.apply(tables[.contents] ?? [])
    }

    private func saveToDisk() {
        let cache = Cache(tsCache: tsCache,
                          tables: Dictionary(uniqueKeysWithValues: tables.map { ($0.key.rawValue, $0.value) }),
                          languages: languages,
                          states: states)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
