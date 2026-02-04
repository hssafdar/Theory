import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import WidgetKit
import SafariServices
import Combine

// MARK: - 1. SHARED CONSTANTS
let APP_GROUP_ID = "group.com.theory.quotes"

// MARK: - 2. DATA MODELS

struct Quote: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let originalText: String
    let author: String
    let workTitle: String
    let year: String
    let sequentialID: Int
    let isSatire: Bool
    
    // STABLE PERSISTENCE ID
    var persistenceID: String { "\(author)-\(workTitle)-\(sequentialID)" }
    
    func displayText(stripCitations: Bool, stripQuotes: Bool) -> String {
        var t = originalText
        if stripCitations {
            t = t.replacingOccurrences(of: "\\[(source: )?\\d+\\]", with: "", options: .regularExpression)
        }
        if stripQuotes {
            if t.hasPrefix("\"") { t.removeFirst() }
            if t.hasSuffix("\"") { t.removeLast() }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    init(id: UUID = UUID(), text: String, author: String, workTitle: String, year: String, sequentialID: Int = 0, isSatire: Bool = false) {
        self.id = id
        self.originalText = text
        self.author = author
        self.workTitle = workTitle
        self.year = year
        self.sequentialID = sequentialID
        self.isSatire = isSatire
    }
}

struct Author: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let profileImagePath: String?
    var works: [Work]
    var isSingleWork: Bool { works.count == 1 }
    var totalQuoteCount: Int { works.reduce(0) { $0 + $1.quotes.count } }
}

struct Work: Identifiable, Hashable, Sendable {
    let id = UUID()
    let title: String
    let year: String
    let authorName: String
    let sourceURL: String?
    let isSatire: Bool
    var quotes: [Quote]
}

struct SavedQueue: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let quoteIDs: [String]
    let dateCreated: Date
    init(id: UUID = UUID(), name: String, quoteIDs: [String]) {
        self.id = id; self.name = name; self.quoteIDs = quoteIDs; self.dateCreated = Date()
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google = "Google"
    case perplexity = "Perplexity"
    var id: String { self.rawValue }
}

enum LaunchQueueOption: String, CaseIterable, Identifiable {
    case active = "Active Feed"
    case starred = "Starred Figures"
    case favorites = "Favorites"
    case savedQueue = "Saved Queue"
    case shuffleAll = "Shuffle All Quotes"
    case empty = "Empty"
    var id: String { self.rawValue }
}

// SHARED WIDGET MODELS
struct WidgetQuoteData: Codable, Sendable {
    let id: String; let text: String; let author: String; let work: String; let year: String; let sequentialID: Int; var isFavorite: Bool; var queueIndex: Int; var queueTotal: Int
}
struct WidgetDataAuthor: Codable, Identifiable, Sendable {
    let id: String; let name: String; var hasImage: Bool
}

// MARK: - 3. VIEW MODEL

@Observable
class QuoteViewModel {
    var allQuotes: [Quote] = []
    var works: [Work] = []
    var displayItems: [DisplayItem] = []
    var authorsMap: [String: Author] = [:]
    
    // Navigation Path
    var figuresPath = NavigationPath()
    
    // Loading State
    var isLoading = true
    var loadingMessage = "Initializing..."
    var loadingProgress: Double = 0.0
    var loadingDetail = ""
    var isBulkOperationLoading = false
    var bulkOperationMessage = ""
    
    // Preferences
    var searchEngine: SearchEngine = .google
    var launchOption: LaunchQueueOption = .active
    var launchSavedQueueID: String? = nil
    var showSatireInFeed: Bool = false
    var hideCitations: Bool = true
    var hideQuotes: Bool = true
    var hideFeedButtons: Bool = false
    var hideAuthorMetadata: Bool = false
    var showExplainButton: Bool = false
    var tapDiscoverToShuffle: Bool = false
    var hideToolbarButton: Bool = false
    
    // Feeds & Queues
    var mainFeedQuotes: [Quote] = []
    var activeQueue: [Quote] = []
    var savedQueues: [SavedQueue] = []
    var currentQuoteID: String? = nil
    var currentQueueName: String = "Active Feed"
    var isShuffleLoading = false
    
    // Persistence
    var favoriteIDs: Set<String> = []
    var starredAuthorIDs: Set<String> = []
    var viewedIDs: Set<String> = []
    var excludedWorks: Set<String> = []
    var notBasedIDs: Set<String> = []
    var disabledQuoteIDs: Set<String> = []
    var authorTypeOverrides: [String: Bool] = [:]
    
    var activeQuoteCount: Int { mainFeedQuotes.count }
    var activeQueueIndex: Int {
        guard let id = currentQuoteID else { return 0 }
        return activeQueue.firstIndex(where: { $0.persistenceID == id }) ?? 0
    }
    
    init() {
        setupFileSystem()
        loadPersistence()
        registerShortcuts()
        Task { await loadDataAsync() }
    }
    
    // MARK: - DATA LOADING
    func loadDataAsync() async {
        let (loadedQuotes, loadedAuthors, loadedWorks) = await Task.detached(priority: .high) {
            return self.parseFiles(reportProgress: { progress, file in
                Task { @MainActor in
                    self.loadingProgress = progress
                    self.loadingDetail = "Loading \(file)..."
                }
            })
        }.value
        
        await MainActor.run {
            self.loadingMessage = "Optimizing Database..."
            self.loadingProgress = 0.95
            
            self.allQuotes = loadedQuotes
            self.works = loadedWorks
            for author in loadedAuthors { self.authorsMap[author.name] = author }
            
            self.buildQueue(from: loadedAuthors)
            self.refreshFeed()
            
            // Load Saved Queues from Disk
            self.loadSavedQueuesFromDisk()
            
            // Handle Launch Option
            switch self.launchOption {
            case .active:
                self.buildMainFeedQueue()
            case .empty:
                self.setQueue(to: [], name: "Empty")
            case .shuffleAll:
                self.loadAllQuotesQueue()
            case .starred:
                self.loadStarredQueue()
            case .favorites:
                self.loadFavoritesQueue()
            case .savedQueue:
                if let idStr = self.launchSavedQueueID,
                   let uuid = UUID(uuidString: idStr),
                   let queue = self.savedQueues.first(where: { $0.id == uuid }) {
                    self.loadingMessage = "Loading Saved Queue..."
                    self.loadSavedQueue(queue)
                } else {
                    self.buildMainFeedQueue()
                }
            }
            
            if let shared = UserDefaults(suiteName: APP_GROUP_ID), let widgetFavs = shared.array(forKey: "widget_favorites") as? [String] {
                let widgetSet = Set(widgetFavs)
                if !widgetSet.isSubset(of: self.favoriteIDs) { self.favoriteIDs.formUnion(widgetSet); self.savePersistence() }
            }
            
            self.syncWidgetData(authors: loadedAuthors)
            self.isLoading = false
        }
    }
    
    // MARK: - FILE SYSTEM PERSISTENCE (SAVED QUEUES)
    private func getSavedQueuesURL() -> URL? {
        guard let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = docURL.appendingPathComponent("SavedQueues")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
    
    func loadSavedQueuesFromDisk() {
        guard let url = getSavedQueuesURL() else { return }
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            var loaded: [SavedQueue] = []
            for fileURL in fileURLs {
                if fileURL.pathExtension == "json", let data = try? Data(contentsOf: fileURL) {
                    if let queue = try? JSONDecoder().decode(SavedQueue.self, from: data) {
                        loaded.append(queue)
                    }
                }
            }
            self.savedQueues = loaded.sorted(by: { $0.dateCreated > $1.dateCreated })
        } catch { print("Error loading saved queues: \(error)") }
    }
    
    func saveQueueToDisk(_ queue: SavedQueue) {
        guard let url = getSavedQueuesURL() else { return }
        let fileURL = url.appendingPathComponent("\(queue.id.uuidString).json")
        if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: fileURL)
        }
    }
    
    func deleteSavedQueueFromDisk(_ queue: SavedQueue) {
        guard let url = getSavedQueuesURL() else { return }
        let fileURL = url.appendingPathComponent("\(queue.id.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    // MARK: - SHORTCUTS
    func registerShortcuts() {
        let items = [
            UIApplicationShortcutItem(type: "PlayFavorites", localizedTitle: "Play Favorites", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "heart.fill"), userInfo: nil),
            UIApplicationShortcutItem(type: "PlayStarred", localizedTitle: "Play Starred", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "star.fill"), userInfo: nil),
            UIApplicationShortcutItem(type: "ShuffleAll", localizedTitle: "Shuffle All", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "shuffle"), userInfo: nil)
        ]
        UIApplication.shared.shortcutItems = items
    }
    
    func handleShortcut(_ type: String) -> Int? {
        self.isShuffleLoading = true
        Task.detached {
            try? await Task.sleep(nanoseconds: 700_000_000)
            await MainActor.run {
                switch type {
                case "PlayFavorites": self.loadFavoritesQueue()
                case "PlayStarred": self.loadStarredQueue()
                case "ShuffleAll": self.loadAllQuotesQueue()
                default: break
                }
                self.isShuffleLoading = false
            }
        }
        return 0
    }
    
    // MARK: - NAVIGATION
    func navigateToWork(for quote: Quote) {
        if let author = authorsMap[quote.author], let work = author.works.first(where: { $0.title == quote.workTitle }) {
            figuresPath = NavigationPath()
            figuresPath.append(author)
            figuresPath.append(work)
        }
    }
    
    // MARK: - QUEUE MANAGEMENT
    func refreshFeed() {
        let activeNames = getActiveAuthorNames()
        self.mainFeedQuotes = allQuotes.filter { quote in
            activeNames.contains(quote.author) &&
            !excludedWorks.contains(quote.workTitle) &&
            !notBasedIDs.contains(quote.persistenceID) &&
            !disabledQuoteIDs.contains(quote.persistenceID) &&
            (showSatireInFeed ? true : !quote.isSatire)
        }
    }
    
    func buildMainFeedQueue() {
        refreshFeed()
        self.activeQueue = mainFeedQuotes.shuffled()
        self.currentQueueName = "Active Feed"
        if let first = activeQueue.first { currentQuoteID = first.persistenceID }
        syncWidgetData()
    }
    
    func loadStarredQueue() {
        let starred = allQuotes.filter { isStarred($0.author) && !isDisabled($0) }.shuffled()
        setQueue(to: starred, name: "Starred Figures")
    }
    
    func loadFavoritesQueue() {
        let favs = allQuotes.filter { isFavorite($0) && !isDisabled($0) }.shuffled()
        setQueue(to: favs, name: "Favorites")
    }
    
    func loadAllQuotesQueue() {
        let all = allQuotes.filter { !isDisabled($0) && !isNotBased($0) && (showSatireInFeed ? true : !$0.isSatire) }.shuffled()
        setQueue(to: all, name: "All Quotes")
    }
    
    func refreshActiveQueue() {
        isShuffleLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.currentQueueName == "Active Feed" {
                self.refreshFeed()
                self.activeQueue = self.mainFeedQuotes.shuffled()
            } else if self.currentQueueName == "All Quotes" {
                self.loadAllQuotesQueue()
            } else {
                self.activeQueue.shuffle()
            }
            if let first = self.activeQueue.first { self.currentQuoteID = first.persistenceID }
            self.isShuffleLoading = false
            self.syncWidgetData()
        }
    }
    
    func setQueue(to quotes: [Quote], name: String = "Custom Queue") {
        DispatchQueue.main.async {
            self.activeQueue = quotes
            self.currentQueueName = name
            if let first = quotes.first { self.currentQuoteID = first.persistenceID }
            self.syncWidgetData()
        }
    }
    
    func addToCurrentQueue(_ quotes: [Quote]) {
        self.isBulkOperationLoading = true
        self.bulkOperationMessage = "Added \(quotes.count) quotes!"
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                self.activeQueue.append(contentsOf: quotes)
                self.isBulkOperationLoading = false
                self.syncWidgetData()
            }
        }
    }
    
    func removeFromQueue(_ quote: Quote) {
        if let index = activeQueue.firstIndex(where: { $0.persistenceID == quote.persistenceID }) {
            activeQueue.remove(at: index)
            syncWidgetData()
        }
    }
    
    func saveQueue(name: String) {
        let ids = activeQueue.map { $0.persistenceID }
        let newQueue = SavedQueue(name: name, quoteIDs: ids)
        savedQueues.append(newQueue)
        saveQueueToDisk(newQueue)
        savePersistence()
    }
    
    func loadSavedQueue(_ queue: SavedQueue) {
        let loaded = queue.quoteIDs.compactMap { id in self.allQuotes.first(where: { $0.persistenceID == id }) }
        if !loaded.isEmpty {
            self.setQueue(to: loaded, name: queue.name)
        }
    }
    
    func deleteSavedQueue(at offsets: IndexSet) {
        offsets.forEach { index in
            let queue = savedQueues[index]
            deleteSavedQueueFromDisk(queue)
        }
        savedQueues.remove(atOffsets: offsets)
        savePersistence()
    }
    
    func shuffleQueue() {
        isShuffleLoading = true
        Task.detached {
            let shuffled = self.activeQueue.shuffled()
            await MainActor.run {
                self.activeQueue = shuffled
                self.currentQueueName = "Shuffled Feed"
                if let first = self.activeQueue.first { self.currentQuoteID = first.persistenceID }
                self.isShuffleLoading = false
                self.syncWidgetData()
            }
        }
    }
    
    func addToQueue(_ quotes: [Quote]) { activeQueue.append(contentsOf: quotes); syncWidgetData() }
    func moveQueueItem(from source: IndexSet, to destination: Int) { activeQueue.move(fromOffsets: source, toOffset: destination); syncWidgetData() }
    
    // MARK: - SETTINGS
    func setSearchEngine(_ engine: SearchEngine) { self.searchEngine = engine; savePersistence() }
    func setLaunchOption(_ option: LaunchQueueOption) { self.launchOption = option; savePersistence() }
    func setLaunchSavedQueue(_ id: String) { self.launchSavedQueueID = id; savePersistence() }
    
    // MARK: - BULK ACTIONS
    func bulkToggleAuthors(_ authors: [Author], enable: Bool) {
        isBulkOperationLoading = true
        bulkOperationMessage = enable ? "Enabling..." : "Disabling..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var currentOrder = self.displayItems
            let targetNames = Set(authors.map { $0.name })
            currentOrder.removeAll { item in
                if case .author(let a) = item { return targetNames.contains(a.name) }
                return false
            }
            guard let dividerIndex = currentOrder.firstIndex(of: .divider) else { self.isBulkOperationLoading = false; return }
            let authorItems = authors.map { DisplayItem.author($0) }
            var newOrder = currentOrder
            if enable { newOrder.insert(contentsOf: authorItems, at: 0) } else { newOrder.append(contentsOf: authorItems) }
            self.displayItems = newOrder
            self.saveQueueOrder()
            self.refreshFeed()
            self.bulkOperationMessage = "Done"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.isBulkOperationLoading = false }
        }
    }
    
    func randomizeActiveFigures(isBookMode: Bool) {
        isBulkOperationLoading = true
        bulkOperationMessage = "Rolling Dice..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var currentOrder = self.displayItems
            var targetItems: [DisplayItem] = []
            var otherItems: [DisplayItem] = []
            for item in currentOrder {
                if case .divider = item { continue }
                if case .author(let a) = item {
                    if self.isBook(a) == isBookMode { targetItems.append(item) }
                    else { otherItems.append(item) }
                }
            }
            let shuffledTargets = targetItems.shuffled()
            let activeTargets = Array(shuffledTargets.prefix(5))
            let inactiveTargets = Array(shuffledTargets.dropFirst(5))
            var newActive: [DisplayItem] = []
            var newInactive: [DisplayItem] = []
            var isProcessingActive = true
            for item in self.displayItems {
                if case .divider = item { isProcessingActive = false; continue }
                if case .author(let a) = item {
                    if self.isBook(a) != isBookMode {
                        if isProcessingActive { newActive.append(item) } else { newInactive.append(item) }
                    }
                }
            }
            newActive.append(contentsOf: activeTargets)
            newInactive.append(contentsOf: inactiveTargets)
            var finalOrder = newActive
            finalOrder.append(.divider)
            finalOrder.append(contentsOf: newInactive)
            self.displayItems = finalOrder
            self.saveQueueOrder()
            self.refreshFeed()
            self.bulkOperationMessage = "Rolled!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.isBulkOperationLoading = false }
        }
    }
    
    func replaceQueue(with authors: [Author]) {
        isBulkOperationLoading = true
        bulkOperationMessage = "Replacing Queue..."
        Task.detached {
            let quotes = authors.flatMap { $0.works.flatMap { $0.quotes } }.shuffled()
            await MainActor.run {
                self.setQueue(to: quotes, name: "Replaced Queue")
                self.isBulkOperationLoading = false
            }
        }
    }
    
    func resetToDefaults() { resetOrder(); refreshFeed() }
    func clearStarred() { starredAuthorIDs.removeAll(); savePersistence() }
    func toggleAuthorType(for author: Author) { let currentIsBook = isBook(author); authorTypeOverrides[author.name] = !currentIsBook; savePersistence() }
    func isBook(_ author: Author) -> Bool { if let override = authorTypeOverrides[author.name] { return override }; return author.isSingleWork }
    
    // MARK: - ACTIONS
    func toggleFavorite(_ quote: Quote) {
        if favoriteIDs.contains(quote.persistenceID) { favoriteIDs.remove(quote.persistenceID) }
        else { favoriteIDs.insert(quote.persistenceID) }
        savePersistence()
        syncWidgetData()
    }
    func toggleStar(for authorName: String) { if starredAuthorIDs.contains(authorName) { starredAuthorIDs.remove(authorName) } else { starredAuthorIDs.insert(authorName) }; savePersistence() }
    func toggleNotBased(_ quote: Quote) { if notBasedIDs.contains(quote.persistenceID) { notBasedIDs.remove(quote.persistenceID) } else { notBasedIDs.insert(quote.persistenceID) }; savePersistence() }
    func hideQuote(_ quote: Quote) { disabledQuoteIDs.insert(quote.persistenceID); if let idx = activeQueue.firstIndex(where: { $0.persistenceID == quote.persistenceID }) { activeQueue.remove(at: idx) }; savePersistence() }
    func unhideQuote(_ quote: Quote) { disabledQuoteIDs.remove(quote.persistenceID); savePersistence() }
    func toggleDisabled(_ quote: Quote) { if disabledQuoteIDs.contains(quote.persistenceID) { unhideQuote(quote) } else { hideQuote(quote) } }
    func clearHidden() { disabledQuoteIDs.removeAll(); savePersistence() }
    func clearDisliked() { notBasedIDs.removeAll(); savePersistence() }
    func toggleWorkExclusion(for workTitle: String) { if excludedWorks.contains(workTitle) { excludedWorks.remove(workTitle) } else { excludedWorks.insert(workTitle) }; savePersistence(); refreshFeed() }
    
    func isStarred(_ authorName: String) -> Bool { starredAuthorIDs.contains(authorName) }
    func findQuote(by persistenceID: String) -> Quote? { allQuotes.first(where: { $0.persistenceID == persistenceID }) }
    func isFavorite(_ quote: Quote) -> Bool { favoriteIDs.contains(quote.persistenceID) }
    func isNotBased(_ quote: Quote) -> Bool { notBasedIDs.contains(quote.persistenceID) }
    func isDisabled(_ quote: Quote) -> Bool { disabledQuoteIDs.contains(quote.persistenceID) }
    func isWorkExcluded(_ workTitle: String) -> Bool { excludedWorks.contains(workTitle) }
    func getViewedCount(for work: Work) -> Int { work.quotes.filter { viewedIDs.contains($0.persistenceID) }.count }
    func markAsViewed(_ quote: Quote) { if !viewedIDs.contains(quote.persistenceID) { viewedIDs.insert(quote.persistenceID); savePersistence() }; if quote.persistenceID != currentQuoteID { currentQuoteID = quote.persistenceID; syncWidgetData() } }
    func resetReadHistory() { viewedIDs.removeAll(); savePersistence() }

    func savePersistence() {
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "Favorites")
        UserDefaults.standard.set(Array(viewedIDs), forKey: "Viewed")
        UserDefaults.standard.set(Array(excludedWorks), forKey: "ExcludedWorks")
        UserDefaults.standard.set(Array(notBasedIDs), forKey: "NotBased")
        UserDefaults.standard.set(Array(disabledQuoteIDs), forKey: "DisabledQuotes")
        UserDefaults.standard.set(Array(starredAuthorIDs), forKey: "StarredAuthors")
        UserDefaults.standard.set(showSatireInFeed, forKey: "ShowSatire")
        UserDefaults.standard.set(hideCitations, forKey: "HideCitations")
        UserDefaults.standard.set(hideQuotes, forKey: "HideQuotes")
        UserDefaults.standard.set(hideFeedButtons, forKey: "HideFeedButtons")
        UserDefaults.standard.set(hideAuthorMetadata, forKey: "HideAuthorMetadata")
        UserDefaults.standard.set(showExplainButton, forKey: "ShowExplainButton")
        UserDefaults.standard.set(tapDiscoverToShuffle, forKey: "TapDiscoverToShuffle")
        UserDefaults.standard.set(hideToolbarButton, forKey: "HideToolbarButton")
        UserDefaults.standard.set(searchEngine.rawValue, forKey: "SearchEngine")
        UserDefaults.standard.set(launchOption.rawValue, forKey: "LaunchOption")
        if let launchID = launchSavedQueueID { UserDefaults.standard.set(launchID, forKey: "LaunchSavedQueueID") }
        UserDefaults.standard.set(authorTypeOverrides, forKey: "AuthorTypeOverrides")
        // SavedQueues are now on disk, but we keep this for legacy/backup if needed, though disk is primary
        if let shared = UserDefaults(suiteName: APP_GROUP_ID) { shared.set(Array(favoriteIDs), forKey: "widget_favorites") }
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    private func loadPersistence() {
        if let savedFavs = UserDefaults.standard.array(forKey: "Favorites") as? [String] { favoriteIDs = Set(savedFavs) }
        if let savedViewed = UserDefaults.standard.array(forKey: "Viewed") as? [String] { viewedIDs = Set(savedViewed) }
        if let savedWorks = UserDefaults.standard.array(forKey: "ExcludedWorks") as? [String] { excludedWorks = Set(savedWorks) }
        if let savedNotBased = UserDefaults.standard.array(forKey: "NotBased") as? [String] { notBasedIDs = Set(savedNotBased) }
        if let savedDisabled = UserDefaults.standard.array(forKey: "DisabledQuotes") as? [String] { disabledQuoteIDs = Set(savedDisabled) }
        if let savedStars = UserDefaults.standard.array(forKey: "StarredAuthors") as? [String] { starredAuthorIDs = Set(savedStars) }
        if let savedOverrides = UserDefaults.standard.dictionary(forKey: "AuthorTypeOverrides") as? [String: Bool] { authorTypeOverrides = savedOverrides }
        
        showSatireInFeed = UserDefaults.standard.bool(forKey: "ShowSatire")
        hideCitations = UserDefaults.standard.object(forKey: "HideCitations") as? Bool ?? true
        hideQuotes = UserDefaults.standard.object(forKey: "HideQuotes") as? Bool ?? true
        hideFeedButtons = UserDefaults.standard.bool(forKey: "HideFeedButtons")
        hideAuthorMetadata = UserDefaults.standard.bool(forKey: "HideAuthorMetadata")
        showExplainButton = UserDefaults.standard.bool(forKey: "ShowExplainButton")
        tapDiscoverToShuffle = UserDefaults.standard.bool(forKey: "TapDiscoverToShuffle")
        hideToolbarButton = UserDefaults.standard.bool(forKey: "HideToolbarButton")
        
        if let e = UserDefaults.standard.string(forKey: "SearchEngine"), let se = SearchEngine(rawValue: e) { searchEngine = se }
        if let l = UserDefaults.standard.string(forKey: "LaunchOption"), let lo = LaunchQueueOption(rawValue: l) { launchOption = lo }
        if let launchID = UserDefaults.standard.string(forKey: "LaunchSavedQueueID") { launchSavedQueueID = launchID }
    }
    
    // MARK: - FILES
    private func setupFileSystem() {
        let fileManager = FileManager.default; guard let docURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let worksDestURL = docURL.appendingPathComponent("Works")
        if !fileManager.fileExists(atPath: worksDestURL.path) { try? fileManager.createDirectory(at: worksDestURL, withIntermediateDirectories: true) }
        if let bundleWorksURL = Bundle.main.url(forResource: "Works", withExtension: nil), let authorDirs = try? fileManager.contentsOfDirectory(at: bundleWorksURL, includingPropertiesForKeys: nil) {
            for authorDir in authorDirs {
                let authorName = authorDir.lastPathComponent; let destAuthorDir = worksDestURL.appendingPathComponent(authorName)
                if !fileManager.fileExists(atPath: destAuthorDir.path) { try? fileManager.createDirectory(at: destAuthorDir, withIntermediateDirectories: true) }
                if let files = try? fileManager.contentsOfDirectory(at: authorDir, includingPropertiesForKeys: nil) {
                    for file in files {
                        let destFile = destAuthorDir.appendingPathComponent(file.lastPathComponent)
                        if !fileManager.fileExists(atPath: destFile.path) { try? fileManager.copyItem(at: file, to: destFile) }
                    }
                }
            }
        }
        _ = getSavedQueuesURL()
    }
    
    nonisolated private func parseFiles(reportProgress: @escaping (Double, String) -> Void) -> ([Quote], [Author], [Work]) {
        var tempQuotes: [Quote] = []; var tempAuthors: [Author] = []; var tempWorks: [Work] = []
        let fileManager = FileManager.default
        guard let docURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return ([], [], []) }
        let worksURL = docURL.appendingPathComponent("Works")
        
        do {
            let authorURLs = try fileManager.contentsOfDirectory(at: worksURL, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            var globalIDCounter = 1
            let totalAuthors = Double(authorURLs.count)
            
            for (index, authorURL) in authorURLs.enumerated() {
                if authorURL.lastPathComponent.hasPrefix(".") { continue }
                let authorName = authorURL.lastPathComponent
                var imagePath: String? = nil
                let fileURLs = try fileManager.contentsOfDirectory(at: authorURL, includingPropertiesForKeys: nil)
                if let exact = fileURLs.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == authorName.lowercased() && ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }) { imagePath = exact.path }
                else if let any = fileURLs.first(where: { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }) { imagePath = any.path }
                
                let workURLs = fileURLs.filter { $0.pathExtension == "txt" }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                var currentAuthorWorks: [Work] = []
                
                for workURL in workURLs {
                    let fileName = workURL.deletingPathExtension().lastPathComponent
                    reportProgress(Double(index) / totalAuthors, fileName)
                    let components = fileName.components(separatedBy: "_")
                    let year = components.last ?? "Unknown Year"
                    let isSatire = fileName.localizedCaseInsensitiveContains("Satire")
                    let title = components.dropLast().joined(separator: "_").replacingOccurrences(of: "SATIRE", with: "", options: .caseInsensitive).trimmingCharacters(in: .punctuationCharacters)
                    
                    if let content = try? String(contentsOf: workURL, encoding: .utf8) {
                        var rawLines = content.components(separatedBy: .newlines)
                        var sourceURL: String? = nil
                        if let firstLine = rawLines.first, (firstLine.contains("http://") || firstLine.contains("https://")) {
                            sourceURL = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                            rawLines.removeFirst()
                        }
                        
                        let quotes: [Quote] = rawLines.compactMap { line in
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty || (trimmed.count < 5) { return nil }
                            let quote = Quote(text: trimmed, author: authorName, workTitle: title, year: year, sequentialID: globalIDCounter, isSatire: isSatire)
                            globalIDCounter += 1
                            return quote
                        }
                        let work = Work(title: title, year: year, authorName: authorName, sourceURL: sourceURL, isSatire: isSatire, quotes: quotes)
                        currentAuthorWorks.append(work); tempQuotes.append(contentsOf: quotes); tempWorks.append(work)
                    }
                }
                if !currentAuthorWorks.isEmpty { tempAuthors.append(Author(name: authorName, profileImagePath: imagePath, works: currentAuthorWorks)) }
            }
        } catch { print("Error parsing: \(error)") }
        return (tempQuotes, tempAuthors, tempWorks)
    }
    
    func importSingleTextFile(url: URL, manualYear: String? = nil) {
        guard url.startAccessingSecurityScopedResource() else { return }; defer { url.stopAccessingSecurityScopedResource() }
        let fileManager = FileManager.default; guard let docURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let worksURL = docURL.appendingPathComponent("Works")
        let filename = url.deletingPathExtension().lastPathComponent
        let components = filename.components(separatedBy: "_")
        var authorName = "Imported"; var finalFileName = filename
        if components.count >= 2 { authorName = components[0] }
        if let year = manualYear, !filename.contains("_\(year)") { finalFileName = "\(filename)_\(year)" }
        let authorDir = worksURL.appendingPathComponent(authorName)
        try? fileManager.createDirectory(at: authorDir, withIntermediateDirectories: true)
        let destURL = authorDir.appendingPathComponent(finalFileName + ".txt")
        if fileManager.fileExists(atPath: destURL.path) { try? fileManager.removeItem(at: destURL) }
        try? fileManager.copyItem(at: url, to: destURL)
        Task { await loadDataAsync() }
    }
    func importAuthorFolder(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }; defer { url.stopAccessingSecurityScopedResource() }
        let fileManager = FileManager.default; guard let docURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let worksURL = docURL.appendingPathComponent("Works"); let destURL = worksURL.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destURL.path) { try? fileManager.removeItem(at: destURL) }
        try? fileManager.copyItem(at: url, to: destURL); Task { await loadDataAsync() }
    }
    
    // Helpers
    private func getActiveAuthorNames() -> Set<String> {
        var names = Set<String>()
        for item in displayItems { if case .divider = item { break }; if case .author(let author) = item { names.insert(author.name) } }
        return names
    }
    private func buildQueue(from authors: [Author]) {
        let savedOrder = UserDefaults.standard.array(forKey: "QueueOrder") as? [String] ?? []
        var organizedItems: [DisplayItem] = []
        var remainingAuthors = authors
        if !savedOrder.isEmpty { for name in savedOrder { if name == "DIVIDER_TOKEN" { organizedItems.append(.divider) } else if let index = remainingAuthors.firstIndex(where: { $0.name == name }) { organizedItems.append(.author(remainingAuthors[index])); remainingAuthors.remove(at: index) } } }
        else { let defaults = ["Karl Marx", "Friedrich Engels", "Marx", "Engels", "Lenin"]; for def in defaults { if let index = remainingAuthors.firstIndex(where: { $0.name.contains(def) }) { organizedItems.append(.author(remainingAuthors[index])); remainingAuthors.remove(at: index) } }; organizedItems.append(.divider) }
        for author in remainingAuthors { organizedItems.append(.author(author)) }
        if !organizedItems.contains(where: { if case .divider = $0 { return true }; return false }) { organizedItems.insert(.divider, at: 0) }
        self.displayItems = organizedItems
    }
    func moveItem(from source: IndexSet, to destination: Int) { displayItems.move(fromOffsets: source, toOffset: destination); saveQueueOrder() }
    func toggleQueueStatus(for author: Author) {
        guard let currentIndex = displayItems.firstIndex(where: { if case .author(let a) = $0 { return a.id == author.id }; return false }) else { return }
        guard let dividerIndex = displayItems.firstIndex(of: .divider) else { return }
        var newItems = displayItems; let item = newItems.remove(at: currentIndex); _ = newItems.firstIndex(of: .divider) ?? 0
        if currentIndex < dividerIndex { newItems.append(item) } else { newItems.insert(item, at: 0) }
        displayItems = newItems; saveQueueOrder()
        refreshFeed() // Update count
    }
    func isActive(_ author: Author) -> Bool {
        guard let authorIndex = displayItems.firstIndex(where: { if case .author(let a) = $0 { return a.id == author.id }; return false }) else { return false }
        guard let dividerIndex = displayItems.firstIndex(of: .divider) else { return false }
        return authorIndex < dividerIndex
    }
    func resetOrder() { let allAuthors = displayItems.compactMap { item -> Author? in if case .author(let a) = item { return a } else { return nil } }; UserDefaults.standard.removeObject(forKey: "QueueOrder"); buildQueue(from: allAuthors); saveQueueOrder(); refreshFeed() }
    private func saveQueueOrder() { let orderStrings: [String] = displayItems.map { item in switch item { case .author(let a): return a.name; case .divider: return "DIVIDER_TOKEN" } }; UserDefaults.standard.set(orderStrings, forKey: "QueueOrder") }
    func updateAuthorImage(author: Author, imageData: Data) { let fileManager = FileManager.default; guard let docURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }; let authorFolder = docURL.appendingPathComponent("Works").appendingPathComponent(author.name); let destinationURL = authorFolder.appendingPathComponent("\(author.name).jpg"); try? imageData.write(to: destinationURL); Task { await loadDataAsync() } }
    func syncWidgetData(authors: [Author]? = nil) {
        guard let sharedDefaults = UserDefaults(suiteName: APP_GROUP_ID) else { return }
        let widgetQuotes = activeQueue.isEmpty ? allQuotes.prefix(50).map { $0 } : activeQueue
        let widgetData = widgetQuotes.enumerated().map { (index, quote) in
            WidgetQuoteData(id: quote.persistenceID, text: quote.displayText(stripCitations: true, stripQuotes: true), author: quote.author, work: quote.workTitle, year: quote.year, sequentialID: quote.sequentialID, isFavorite: favoriteIDs.contains(quote.persistenceID), queueIndex: index + 1, queueTotal: widgetQuotes.count)
        }
        if let encoded = try? JSONEncoder().encode(widgetData) { sharedDefaults.set(encoded, forKey: "widget_all_quotes") }
        sharedDefaults.set(Array(favoriteIDs), forKey: "widget_favorites")
        if let encodedQueues = try? JSONEncoder().encode(savedQueues.map { $0.name }) { sharedDefaults.set(encodedQueues, forKey: "widget_saved_queues_names") }
        let authorList = authors ?? []; var widgetAuthors: [WidgetDataAuthor] = []
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_ID) {
            let imagesDir = containerURL.appendingPathComponent("AuthorImages"); try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            for author in authorList { var hasImg = false; if let localPath = author.profileImagePath, let imageData = try? Data(contentsOf: URL(fileURLWithPath: localPath)) { let sharedPath = imagesDir.appendingPathComponent("\(author.name).jpg"); try? imageData.write(to: sharedPath); hasImg = true }; widgetAuthors.append(WidgetDataAuthor(id: author.name, name: author.name, hasImage: hasImg)) }
        }
        if let encodedAuthors = try? JSONEncoder().encode(widgetAuthors) { sharedDefaults.set(encodedAuthors, forKey: "widget_authors_list") }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

enum DisplayItem: Identifiable, Hashable { case author(Author); case divider; var id: String { switch self { case .author(let a): return a.id.uuidString; case .divider: return "DIVIDER" } } }

// MARK: - 4. UI VIEWS

struct ContentView: View {
    @State private var viewModel = QuoteViewModel()
    @State private var deepLinkToast: String? = nil
    @Binding var deepLinkQuoteID: String?
    @State private var scrollToQuoteID: String? = nil
    @State private var selectedTab = 0
    
    @State private var pendingFile: URL? = nil
    @State private var showYearPrompt = false
    @State private var manualYear = ""
    
    var body: some View {
        ZStack {
            if viewModel.isLoading {
                SplashScreen(progress: viewModel.loadingProgress, message: viewModel.loadingMessage, detail: viewModel.loadingDetail)
            } else {
                TabView(selection: Binding(get: { selectedTab }, set: { newTab in
                    selectedTab = newTab
                    if newTab == 0 && viewModel.activeQueue.isEmpty { viewModel.buildMainFeedQueue() }
                })) {
                    FeedContainerView(viewModel: viewModel, scrollToQuoteID: $scrollToQuoteID)
                        .tabItem { Label("Discover", systemImage: "sparkles.rectangle.stack") }
                        .tag(0)
                    
                    FiguresView(viewModel: viewModel, pendingFile: $pendingFile, showYearPrompt: $showYearPrompt, selectedTab: $selectedTab)
                        .tabItem { Label("Figures", systemImage: "person.2.crop.square.stack") }
                        .tag(1)
                    
                    LibraryView(viewModel: viewModel, selectedTabBinding: $selectedTab)
                        .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                        .tag(2)
                }
                .preferredColorScheme(.dark)
                .onChange(of: deepLinkQuoteID) { _, newValue in
                    if let id = newValue {
                        if let quote = viewModel.findQuote(by: id) {
                            viewModel.setQueue(to: [quote])
                            selectedTab = 0
                        }
                        deepLinkQuoteID = nil
                    }
                }
                .onContinueUserActivity("UIApplicationShortcutItem") { userActivity in
                    if let type = userActivity.userInfo?["type"] as? String {
                        if let tab = viewModel.handleShortcut(type) { selectedTab = tab }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToFigures"))) { _ in
                    selectedTab = 1
                }
            }
            if let message = deepLinkToast {
                VStack {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundColor(.white).padding(12).background(Circle().stroke(Color.white, lineWidth: 3))
                        Text("Copied").font(.title3).bold().foregroundColor(.white)
                        Text(message).font(.caption).foregroundColor(.white.opacity(0.8))
                    }
                    .padding(30).background(Color.black.opacity(0.8)).cornerRadius(25).shadow(radius: 20)
                    Spacer()
                }
                .padding(.top, 100).zIndex(100)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { deepLinkToast = nil } }
            }
        }
        .onOpenURL { url in
            if url.absoluteString.contains("theoryapp://copy/") {
                let id = url.absoluteString.replacingOccurrences(of: "theoryapp://copy/", with: "").removingPercentEncoding ?? ""
                if let quote = viewModel.findQuote(by: id) {
                    UIPasteboard.general.string = quote.displayText(stripCitations: viewModel.hideCitations, stripQuotes: viewModel.hideQuotes) + " - \(quote.author)"
                    deepLinkToast = "Copied to Clipboard"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } else if url.absoluteString.contains("theoryapp://explain/") {
                let id = url.absoluteString.replacingOccurrences(of: "theoryapp://explain/", with: "").removingPercentEncoding ?? ""
                if let quote = viewModel.findQuote(by: id) { performSearch(quote: quote, engine: viewModel.searchEngine) }
            }
        }
        .alert("Missing Year", isPresented: $showYearPrompt) {
            TextField("Year", text: $manualYear).keyboardType(.numberPad)
            Button("Add with Year") { if let url = pendingFile { viewModel.importSingleTextFile(url: url, manualYear: manualYear) }; pendingFile = nil; manualYear = "" }
            Button("Add without Year") { if let url = pendingFile { viewModel.importSingleTextFile(url: url, manualYear: nil) }; pendingFile = nil; manualYear = "" }
            Button("Cancel", role: .cancel) { pendingFile = nil; manualYear = "" }
        } message: { Text("This file name doesn't contain a year. Would you like to add one?") }
    }
}

// MARK: - FEED CONTAINER
struct FeedContainerView: View {
    var viewModel: QuoteViewModel
    @Binding var scrollToQuoteID: String?
    @State private var showQueueDrawer = false
    @State private var dragOffset: CGFloat = 0
    @State private var showSaveAlert = false
    @State private var queueName = ""
    @State private var showSettingsToolbar = false
    @State private var showSettingsSheet = false
    @State private var isSpinning = false
    @State private var showSaveToast = false
    
    private let drawerWidth: CGFloat = 300
    private let threshold: CGFloat = 80
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Queue Drawer
                QueueDrawerView(viewModel: viewModel, showSaveAlert: $showSaveAlert, scrollToQuoteID: $scrollToQuoteID, showDrawer: $showQueueDrawer)
                    .frame(width: drawerWidth)
                    .offset(x: showQueueDrawer ? 0 : -drawerWidth)
                    .zIndex(2)
                    .transition(.move(edge: .leading))
                
                // Main Feed
                ZStack {
                    if viewModel.activeQueue.isEmpty {
                        // Empty State
                        VStack(spacing: 20) {
                            Image(systemName: "book.closed").font(.largeTitle).foregroundColor(.gray)
                            Text("Queue Empty").font(.title2).bold().foregroundColor(.white)
                            Button(action: { viewModel.buildMainFeedQueue() }) {
                                HStack { Image(systemName: "arrow.clockwise"); Text("Reload Active Queue") }
                                    .padding().background(Color(UIColor.systemGray6)).foregroundColor(.white).cornerRadius(10)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
                    } else if viewModel.isShuffleLoading {
                        VStack(spacing: 20) {
                            ProgressView().scaleEffect(1.5)
                            Text("Shuffling...")
                                .font(.headline).foregroundColor(.white)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: 0) {
                                    ForEach(viewModel.activeQueue, id: \.persistenceID) { quote in
                                        QuoteCard(quote: quote, viewModel: viewModel)
                                            .containerRelativeFrame([.horizontal, .vertical])
                                            .id(quote.persistenceID)
                                            .onAppear { viewModel.markAsViewed(quote) }
                                    }
                                }
                                .scrollTargetLayout()
                            }
                            .scrollTargetBehavior(.paging)
                            .ignoresSafeArea()
                            .background(Color.black)
                            .onChange(of: scrollToQuoteID) { _, target in
                                if let t = target { withAnimation { proxy.scrollTo(t, anchor: .center) } }
                            }
                        }
                    }
                    
                    // TOP BAR
                    VStack {
                        HStack {
                            // RESTORED: Queue Drawer Button (Top Left)
                            Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { showQueueDrawer.toggle() } } label: {
                                Image(systemName: showQueueDrawer ? "chevron.left" : "line.3.horizontal")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white.opacity(0.6))
                                    .frame(width: 40, height: 50)
                                    .background(Color.black.opacity(0.8))
                                    .clipShape(RoundedRectangle(cornerRadius: 15))
                                    .offset(x: -20)
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.top, 60)
                    
                    // BOTTOM LEFT TOOLBAR BUTTON (HANGING OFF)
                    if !viewModel.hideToolbarButton {
                        ZStack(alignment: .bottomLeading) {
                            Color.clear // Container
                            HStack(spacing: 0) {
                                // 1. Toggle Button (Hanging Wrench)
                                Button {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                        showSettingsToolbar.toggle()
                                    }
                                } label: {
                                    ZStack {
                                        // Background for the whole pill is applied to the HStack container below
                                        // This just holds the icon
                                        Image(systemName: showSettingsToolbar ? "chevron.left" : "wrench.fill")
                                            .font(.system(size: 14, weight: .bold)) // Tiny wrench
                                            .foregroundColor(.white.opacity(0.8))
                                            .frame(width: 50, height: 50) // Touch target
                                    }
                                }

                                // 2. Expanded Content
                                if showSettingsToolbar {
                                    HStack(spacing: 12) {
                                        // Vertical Divider
                                        Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 24)

                                        // Feed Info (Stretches)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(viewModel.currentQueueName)
                                                .font(.system(size: 14, weight: .bold)) // Larger text
                                                .foregroundColor(.white)
                                                .lineLimit(1) // Don't wrap
                                                .fixedSize(horizontal: false, vertical: true) // Allow width expansion
                                            
                                            Text("\(viewModel.activeQueue.count) items")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                        }
                                        .layoutPriority(1) // Prioritize text width so it doesn't cut off
                                        
                                        Spacer() // Push buttons to the right

                                        // Shuffle Button
                                        Button {
                                            isSpinning = true
                                            viewModel.refreshActiveQueue()
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isSpinning = false }
                                        } label: {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                                .font(.system(size: 18))
                                                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                                                .foregroundColor(.white)
                                        }

                                        // Settings Dots
                                        Button { showSettingsSheet = true } label: {
                                            Image(systemName: "ellipsis")
                                                .font(.system(size: 18))
                                                .foregroundColor(.white)
                                        }
                                    }
                                    .padding(.trailing, 20) // Right padding inside pill
                                    .frame(maxWidth: .infinity, alignment: .leading) // Fill available space
                                }
                            }
                            .background(Color.black.opacity(0.9)) // Dark background
                            .clipShape(RoundedRectangle(cornerRadius: 15)) // Rounded corners like drawer button
                            .offset(x: -15) // Hang off the left edge
                            // Dynamic width animation
                            .frame(width: showSettingsToolbar ? UIScreen.main.bounds.width - 40 : 50)
                            .padding(.leading, 0) // Reset padding because we are hanging off
                            .padding(.bottom, 10) // Close to bottom (tab bar area)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .blur(radius: showQueueDrawer ? 3 : 0)
                .overlay(showQueueDrawer ? Color.black.opacity(0.3).onTapGesture { withAnimation { showQueueDrawer = false } } : nil)
                .zIndex(1)
                .sheet(isPresented: $showSettingsSheet) {
                    NavigationView {
                        ReadingPreferencesView(viewModel: viewModel)
                            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { showSettingsSheet = false } } }
                    }
                    .presentationDetents([.medium])
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.width > 0 && !showQueueDrawer { if value.startLocation.x < 50 { dragOffset = value.translation.width } }
                            else if value.translation.width < 0 && showQueueDrawer { dragOffset = value.translation.width }
                        }
                        .onEnded { value in
                            if value.translation.width > threshold && !showQueueDrawer { withAnimation { showQueueDrawer = true } }
                            else if value.translation.width < -threshold && showQueueDrawer { withAnimation { showQueueDrawer = false } }
                            dragOffset = 0
                        }
                )
            }
        }
        .background(Color.black)
        .alert("Save Queue", isPresented: $showSaveAlert) {
            TextField("Queue Name", text: $queueName)
            Button("Save") {
                viewModel.saveQueue(name: queueName)
                queueName = ""
                showSaveToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showSaveToast = false }
            }
            Button("Cancel", role: .cancel) { }
        }
        .overlay(showSaveToast ? ToastView(message: "Queue Saved!") : nil)
    }
}

// SHARED PREFERENCES VIEW
struct ReadingPreferencesView: View {
    @Bindable var viewModel: QuoteViewModel
    var body: some View {
        List {
            Section {
                Toggle("Hide Feed Buttons", isOn: $viewModel.hideFeedButtons)
                Toggle("Hide Author/Metadata", isOn: $viewModel.hideAuthorMetadata)
                Toggle("Show Explain Button", isOn: $viewModel.showExplainButton)
                Toggle("Hide Citation #s", isOn: $viewModel.hideCitations)
                Toggle("Hide \"Quotes\"", isOn: $viewModel.hideQuotes)
                Toggle("Show Satire in Feed", isOn: $viewModel.showSatireInFeed)
                Toggle("Tap Discover to Shuffle", isOn: $viewModel.tapDiscoverToShuffle)
                Toggle("Hide Toolbar Button", isOn: $viewModel.hideToolbarButton)
            } header: { Text("Reading Preferences") }
        }
        .navigationTitle("Preferences")
    }
}

struct QueueDrawerView: View {
    var viewModel: QuoteViewModel
    @Binding var showSaveAlert: Bool
    @Binding var scrollToQuoteID: String?
    @Binding var showDrawer: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    Text("Switch Feed")
                    Button { viewModel.buildMainFeedQueue() } label: {
                        if viewModel.currentQueueName == "Active Feed" { Label("Active Feed", systemImage: "checkmark") } else { Text("Active Feed") }
                    }
                    Button { viewModel.loadStarredQueue() } label: {
                        if viewModel.currentQueueName == "Starred Figures" { Label("Starred Figures", systemImage: "checkmark") } else { Text("Starred Figures") }
                    }
                    Button { viewModel.loadFavoritesQueue() } label: {
                        if viewModel.currentQueueName == "Favorites" { Label("Favorites", systemImage: "checkmark") } else { Text("Favorites") }
                    }
                    Button { viewModel.loadAllQuotesQueue() } label: {
                        if viewModel.currentQueueName == "All Quotes" { Label("All Quotes", systemImage: "checkmark") } else { Text("All Quotes") }
                    }
                    
                    if !viewModel.savedQueues.isEmpty {
                        Divider()
                        Text("Saved Queues")
                        ForEach(viewModel.savedQueues) { q in
                            Button { viewModel.loadSavedQueue(q) } label: {
                                if viewModel.currentQueueName == q.name { Label(q.name, systemImage: "checkmark") } else { Text(q.name) }
                            }
                        }
                    }
                    
                    Divider()
                    Button("Shuffle Quotes") { viewModel.refreshActiveQueue() }
                    Button("Clear Queue", role: .destructive) { viewModel.setQueue(to: []) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.currentQueueName).font(.headline).foregroundColor(.white).lineLimit(1)
                            Text("\(viewModel.activeQueue.count) quotes").font(.caption).foregroundColor(.gray)
                        }
                        Image(systemName: "chevron.down").font(.caption).foregroundColor(.gray)
                    }
                }
                Spacer()
                Button(action: {
                    if let current = viewModel.currentQuoteID {
                        scrollToQuoteID = nil
                        DispatchQueue.main.async { scrollToQuoteID = current }
                    }
                }) { Image(systemName: "scope").foregroundColor(.blue) }.padding(.trailing, 8)
                
                Button(action: { showSaveAlert = true }) { Image(systemName: "square.and.arrow.down").foregroundColor(.blue) }
            }
            .padding().padding(.top, 50).background(Color(UIColor.systemGray6))
            
            ScrollViewReader { proxy in
                List {
                    ForEach(viewModel.activeQueue, id: \.persistenceID) { quote in
                        QueueRow(quote: quote, viewModel: viewModel)
                            .listRowBackground(viewModel.currentQuoteID == quote.persistenceID ? Color.blue.opacity(0.2) : Color.clear)
                            .id(quote.persistenceID)
                            .onTapGesture(count: 2) {
                                scrollToQuoteID = quote.persistenceID
                                withAnimation { showDrawer = false }
                            }
                            .contextMenu {
                                Button { UIPasteboard.general.string = quote.displayText(stripCitations: true, stripQuotes: true) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button { viewModel.removeFromQueue(quote) } label: { Label("Remove from Queue", systemImage: "trash") }
                            }
                    }
                    .onMove { source, dest in viewModel.moveQueueItem(from: source, to: dest) }
                }
                .listStyle(.plain)
                .onChange(of: viewModel.currentQuoteID) { _, newID in
                    if let id = newID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .onChange(of: scrollToQuoteID) { _, target in
                     if let t = target { withAnimation { proxy.scrollTo(t, anchor: .center) } }
                }
            }
        }
        .background(Color(UIColor.systemBackground))
        .edgesIgnoringSafeArea(.vertical)
    }
}

struct QueueRow: View {
    let quote: Quote
    let viewModel: QuoteViewModel
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(quote.author).font(.caption).bold().foregroundColor(.blue)
                    Text("•").font(.caption2).foregroundColor(.gray)
                    Text(quote.workTitle).font(.caption2).foregroundColor(.gray).lineLimit(1)
                }
                Text(quote.displayText(stripCitations: viewModel.hideCitations, stripQuotes: viewModel.hideQuotes)).lineLimit(1).font(.subheadline).foregroundColor(.primary)
            }
            Spacer()
            if viewModel.isFavorite(quote) {
                Image(systemName: "heart.fill").font(.caption).foregroundColor(.red).padding(.trailing, 4)
            }
            if !viewModel.hideCitations { Text("#\(quote.sequentialID)").font(.caption).foregroundColor(.gray) }
        }.padding(.vertical, 4)
    }
}

// MARK: - QUOTE CARD (UNCHANGED)
struct QuoteCard: View {
    let quote: Quote
    var viewModel: QuoteViewModel
    @State private var isHeartAnimating = false
    @State private var showToast = false
    @State private var toastMessage = ""
    
    struct CardButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
                .opacity(configuration.isPressed ? 0.8 : 1.0)
        }
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Button(action: {}) { QuoteContent(quote: quote, viewModel: viewModel) }
            .buttonStyle(CardButtonStyle())
            .contextMenu {
                Button { viewModel.hideQuote(quote) } label: { Label("Hide Quote", systemImage: "eye.slash") }
                Button {
                    viewModel.navigateToWork(for: quote)
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchToFigures"), object: nil)
                } label: { Label("Go to Work", systemImage: "book") }
                Button { copyToClipboard() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { performSearch(quote: quote, engine: viewModel.searchEngine) } label: { Label("Explain", systemImage: "magnifyingglass") }
                if viewModel.activeQueue.contains(where: { $0.id == quote.id }) {
                    Button(role: .destructive) { viewModel.removeFromQueue(quote) } label: { Label("Remove from Queue", systemImage: "trash") }
                }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                withAnimation(.spring()) { viewModel.toggleFavorite(quote); isHeartAnimating = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isHeartAnimating = false }
            })
            if !viewModel.hideFeedButtons { QuoteActionButtons(quote: quote, viewModel: viewModel, showToast: $showToast, toastMessage: $toastMessage) }
            if isHeartAnimating { Image(systemName: "heart.fill").font(.system(size: 100)).foregroundColor(.white.opacity(0.8)).shadow(radius: 10) }
            if showToast { ToastView(message: toastMessage) }
        }
    }
    
    func copyToClipboard() {
        UIPasteboard.general.string = "\"\(quote.displayText(stripCitations: viewModel.hideCitations, stripQuotes: viewModel.hideQuotes))\" - \(quote.author)"
        toastMessage = "Copied to Clipboard"
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { showToast = false } }
    }
}

struct QuoteContent: View {
    let quote: Quote
    let viewModel: QuoteViewModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("“\(quote.displayText(stripCitations: viewModel.hideCitations, stripQuotes: viewModel.hideQuotes))”")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            if !viewModel.hideAuthorMetadata {
                VStack(spacing: 4) {
                    Text(quote.author).font(.headline).foregroundStyle(.yellow)
                    if quote.isSatire { Text("SATIRE").font(.caption).bold().foregroundColor(.black).padding(.horizontal, 6).padding(.vertical, 2).background(Color.yellow).cornerRadius(6) }
                    Text("\(quote.workTitle) • \(quote.year)").font(.caption).foregroundStyle(.gray)
                    if !viewModel.hideCitations { Text("(#\(quote.sequentialID))").font(.system(size: 10)).foregroundStyle(.gray.opacity(0.5)).padding(.top, 4) }
                }.padding(.top, 24)
            }
            Spacer()
        }
    }
}

struct QuoteActionButtons: View {
    let quote: Quote
    let viewModel: QuoteViewModel
    @Binding var showToast: Bool
    @Binding var toastMessage: String
    @State private var isHeartAnimating = false
    @State private var isThumbsDownAnimating = false
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 30) {
                Spacer()
                if viewModel.showExplainButton {
                    Button(action: { performSearch(quote: quote, engine: viewModel.searchEngine) }) {
                        HStack(spacing: 6) { Image(systemName: "magnifyingglass"); Text("Explain").font(.caption).fontWeight(.bold) }
                            .padding(8).background(Color.gray.opacity(0.3)).foregroundColor(.white).clipShape(Capsule())
                    }.padding(.bottom, 10)
                }
                Button(action: { withAnimation(.spring()) { viewModel.toggleFavorite(quote); isHeartAnimating = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { isHeartAnimating = false } }) {
                    VStack { Image(systemName: viewModel.isFavorite(quote) ? "heart.fill" : "heart").font(.system(size: 30)).foregroundStyle(viewModel.isFavorite(quote) ? .red : .white).scaleEffect(isHeartAnimating ? 1.3 : 1.0); Text("Save").font(.caption2).foregroundStyle(.white) }
                }
                Button(action: { withAnimation(.spring()) { viewModel.toggleNotBased(quote); isThumbsDownAnimating = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { isThumbsDownAnimating = false } }) {
                    VStack { Image(systemName: viewModel.isNotBased(quote) ? "hand.thumbsdown.fill" : "hand.thumbsdown").font(.system(size: 28)).foregroundStyle(viewModel.isNotBased(quote) ? .red : .white).scaleEffect(isThumbsDownAnimating ? 1.3 : 1.0); Text("Dislike").font(.caption2).foregroundStyle(.white) }
                }
                ShareLink(item: "\"\(quote.displayText(stripCitations: viewModel.hideCitations, stripQuotes: viewModel.hideQuotes))\"\n— \(quote.author)") {
                    VStack { Image(systemName: "square.and.arrow.up").font(.system(size: 26)).foregroundStyle(.white); Text("Share").font(.caption2).foregroundStyle(.white) }
                }
                Spacer().frame(height: 100)
            }.padding(.trailing, 20)
        }
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        VStack {
            VStack(spacing: 12) {
                Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundColor(.white).padding(12).background(Circle().stroke(Color.white, lineWidth: 3)).shadow(radius: 5)
                Text(message).font(.headline).bold().foregroundColor(.white).multilineTextAlignment(.center)
            }.padding(20).frame(maxWidth: 200).background(Color.black.opacity(0.8)).cornerRadius(20).shadow(radius: 20).transition(.scale.combined(with: .opacity)); Spacer()
        }.padding(.top, 100).zIndex(100)
    }
}

// MARK: - LIST VIEWS (All Quotes, Library, etc.)

struct AllQuotesListView: View {
    var viewModel: QuoteViewModel
    @Binding var selectedTabBinding: Int
    @State private var searchText = ""
    @State private var searchPlaceholder = "Search Quote"
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    var filteredQuotes: [Quote] {
        let cleanText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.isEmpty { return viewModel.allQuotes.filter { !viewModel.isDisabled($0) } }
        return viewModel.allQuotes.filter { !viewModel.isDisabled($0) && ($0.originalText.localizedCaseInsensitiveContains(cleanText) || $0.author.localizedCaseInsensitiveContains(cleanText) || "\($0.sequentialID)".contains(cleanText)) }
    }
    var body: some View {
        VStack {
            List {
                Section(header: Text("\(filteredQuotes.count) Quotes")) {
                    ForEach(filteredQuotes, id: \.persistenceID) { quote in
                        AllQuotesRow(quote: quote, viewModel: viewModel)
                            .onTapGesture { viewModel.setQueue(to: [quote] + filteredQuotes.filter { $0.id != quote.id }, name: "Custom Selection"); selectedTabBinding = 0 }
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPlaceholder)
            .onReceive(timer) { _ in withAnimation { searchPlaceholder = (searchPlaceholder == "Search Quote") ? "Search Quote ID #" : "Search Quote" } }
            Button(action: {
                viewModel.loadAllQuotesQueue()
                selectedTabBinding = 0
            }) {
                HStack { Image(systemName: "shuffle"); Text("Shuffle & Play All") }.font(.headline).frame(maxWidth: .infinity).padding().background(Color.blue).foregroundColor(.white).cornerRadius(12).padding()
            }
        }
        .navigationTitle("All Quotes")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { viewModel.setQueue(to: filteredQuotes, name: "All Quotes"); selectedTabBinding = 0 } label: { Label("Play All", systemImage: "play.circle") } } }
    }
}

struct AllQuotesRow: View {
    let quote: Quote
    var viewModel: QuoteViewModel
    var body: some View {
        VStack(alignment: .leading) {
            Text(quote.displayText(stripCitations: viewModel.hideCitations, stripQuotes: viewModel.hideQuotes)).lineLimit(3).font(.subheadline)
            HStack {
                Text("\(quote.author) - \(quote.year)").font(.caption).foregroundColor(.secondary)
                if quote.isSatire { Text("SATIRE").font(.caption2).bold().foregroundColor(.black).padding(.horizontal, 4).background(Color.yellow).cornerRadius(4) }
                Spacer()
                if !viewModel.hideCitations { Text("#\(quote.sequentialID)").font(.caption2).bold().foregroundColor(.gray) }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { UIPasteboard.general.string = "\"\(quote.displayText(stripCitations: viewModel.hideCitations, stripQuotes: viewModel.hideQuotes))\" - \(quote.author)" } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button { performSearch(quote: quote, engine: viewModel.searchEngine) } label: { Label("Explain", systemImage: "magnifyingglass") }
        }
        .swipeActions(edge: .leading) { Button { viewModel.addToQueue([quote]) } label: { Label("Add", systemImage: "plus") }.tint(.green) }
        .swipeActions(edge: .trailing) { Button { viewModel.toggleDisabled(quote) } label: { Label("Hide", systemImage: "eye.slash") }.tint(.gray) }
    }
}

// MARK: - FIXED LIBRARY VIEW
struct LibraryView: View {
    @Bindable var viewModel: QuoteViewModel
    @Binding var selectedTabBinding: Int
    @State private var showResetConfirm = false
    @State private var showQueueResetAction = false
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Collections")) {
                    NavigationLink(destination: AllQuotesListView(viewModel: viewModel, selectedTabBinding: $selectedTabBinding)) { Label("All Quotes", systemImage: "quote.bubble") }
                    NavigationLink(destination: UnifiedFavoritesView(viewModel: viewModel, selectedTabBinding: $selectedTabBinding)) { Label("Favorites Collection", systemImage: "heart.fill") }
                    NavigationLink(destination: SavedQueuesView(viewModel: viewModel, selectedTabBinding: $selectedTabBinding)) { Label("Saved Queues", systemImage: "music.note.list") }
                    NavigationLink(destination: DislikedHiddenLibraryView(viewModel: viewModel)) { HStack { Label("Disliked / Hidden", systemImage: "eye.slash.fill"); Spacer(); Text("\(viewModel.allQuotes.filter { viewModel.isNotBased($0) || viewModel.isDisabled($0) }.count)").foregroundColor(.secondary) } }
                    NavigationLink(destination: FeedView(quotes: viewModel.allQuotes.filter { $0.isSatire }, viewModel: viewModel)) { HStack { Label("Fake / Satire", systemImage: "theatermasks.fill"); Spacer(); Text("\(viewModel.allQuotes.filter { $0.isSatire }.count)").foregroundColor(.secondary) } }
                }
                
                Section(header: Text("Search Engine")) {
                    Picker("Search With", selection: $viewModel.searchEngine) { Text("Google").tag(SearchEngine.google); Text("Perplexity").tag(SearchEngine.perplexity) }
                }
                
                Section(header: Text("Launch Preference")) {
                    Picker("Queue on Launch", selection: $viewModel.launchOption) {
                        Text("Active Feed").tag(LaunchQueueOption.active)
                        Text("Empty").tag(LaunchQueueOption.empty)
                        Text("Shuffle All Quotes").tag(LaunchQueueOption.shuffleAll)
                        Text("Starred Figures").tag(LaunchQueueOption.starred)
                        Text("Favorites").tag(LaunchQueueOption.favorites)
                        Text("Saved Queue").tag(LaunchQueueOption.savedQueue)
                    }
                    if viewModel.launchOption == .savedQueue {
                        Picker("Select Saved Queue", selection: Binding(get: { viewModel.launchSavedQueueID ?? "" }, set: { viewModel.setLaunchSavedQueue($0) })) {
                            if viewModel.savedQueues.isEmpty { Text("No Saved Queues").tag("") }
                            ForEach(viewModel.savedQueues) { queue in Text(queue.name).tag(queue.id.uuidString) }
                        }
                    }
                }
                
                Section {
                    NavigationLink(destination: ReadingPreferencesView(viewModel: viewModel)) { Text("Reading Preferences") }
                }
                
                Section {
                    Button(role: .destructive, action: { showQueueResetAction = true }) { Label("Reset Queue", systemImage: "arrow.counterclockwise") }
                    Button(role: .destructive, action: { showResetConfirm = true }) { Label("Reset Read History", systemImage: "clock.arrow.circlepath") }
                }
            }
            .navigationTitle("Library")
            .confirmationDialog("Reset Queue", isPresented: $showQueueResetAction) {
                Button("Clear Queue", role: .destructive) { viewModel.setQueue(to: [], name: "Empty") }
                Button("Reset to Active Feed") { viewModel.buildMainFeedQueue() }
                Button("Reset to Default Active Feed") { viewModel.resetToDefaults(); viewModel.buildMainFeedQueue() }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Reset History?", isPresented: $showResetConfirm) { Button("Cancel", role: .cancel) {}; Button("Reset", role: .destructive) { viewModel.resetReadHistory() } }
        }
    }
}

struct SavedQueuesView: View {
    var viewModel: QuoteViewModel
    @Binding var selectedTabBinding: Int
    @State private var loadingQueueID: UUID?
    @State private var showToast = false
    
    var body: some View {
        List {
            if viewModel.savedQueues.isEmpty { Text("No saved queues.") }
            ForEach(viewModel.savedQueues) { queue in
                Button {
                    loadingQueueID = queue.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { viewModel.loadSavedQueue(queue); selectedTabBinding = 0; loadingQueueID = nil }
                } label: {
                    HStack {
                        VStack(alignment: .leading) { Text(queue.name).font(.headline); Text("\(queue.quoteIDs.count) items").font(.caption).foregroundColor(.gray) }
                        Spacer()
                        if loadingQueueID == queue.id { ProgressView().padding(.trailing, 10) }
                        else {
                            HStack(spacing: -8) {
                                ForEach(Array(queue.quoteIDs.prefix(3)), id: \.self) { id in
                                    if let quote = viewModel.findQuote(by: id), let author = viewModel.authorsMap[quote.author] {
                                        if let path = author.profileImagePath, let uiImage = UIImage(contentsOfFile: path) {
                                            Image(uiImage: uiImage).resizable().scaledToFill().frame(width: 24, height: 24).clipShape(Circle()).overlay(Circle().stroke(Color.white, lineWidth: 1))
                                        } else {
                                            Circle().fill(Color.gray).frame(width: 24, height: 24).overlay(Circle().stroke(Color.white, lineWidth: 1))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        // LOAD QUEUE (Add Logic)
                        let quotes = queue.quoteIDs.compactMap { id in viewModel.allQuotes.first(where: { $0.persistenceID == id }) }
                        viewModel.addToCurrentQueue(quotes)
                        showToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showToast = false }
                    } label: { Label("Add to Queue", systemImage: "plus.circle") }.tint(.green)
                }
            }.onDelete(perform: viewModel.deleteSavedQueue)
        }
        .navigationTitle("Saved Queues")
        .overlay(showToast ? ToastView(message: "Added Queue!") : nil)
    }
}

struct UnifiedFavoritesView: View {
    var viewModel: QuoteViewModel
    @Binding var selectedTabBinding: Int
    @State private var filterMode = 0
    var body: some View {
        VStack {
            Picker("Filter", selection: $filterMode) { Text("Active Feed").tag(0); Text("All Favorited").tag(1) }.pickerStyle(SegmentedPickerStyle()).padding()
            List {
                let quotes = filterMode == 0 ? viewModel.mainFeedQuotes.filter { viewModel.isFavorite($0) } : viewModel.allQuotes.filter { viewModel.isFavorite($0) }
                Section(header: HStack {
                    Text("\(quotes.count) Favorites")
                    Spacer()
                    Button(action: { viewModel.addToCurrentQueue(quotes) }) { Image(systemName: "plus.circle") }
                }) {
                    if quotes.isEmpty { Text("No favorites found.") }
                    ForEach(quotes) { quote in AllQuotesRow(quote: quote, viewModel: viewModel).onTapGesture { viewModel.setQueue(to: quotes, name: "Favorites"); selectedTabBinding = 0 } }
                }
                if !viewModel.starredAuthorIDs.isEmpty {
                    Section(header: HStack {
                        Text("Starred Figures")
                        Spacer()
                        Button(action: {
                            let authors = viewModel.displayItems.compactMap { item -> Author? in if case .author(let a) = item, viewModel.isStarred(a.name) { return a } else { return nil } }
                            viewModel.addToCurrentQueue(authors.flatMap { $0.works.flatMap { $0.quotes } })
                        }) { Image(systemName: "plus.circle") }
                    }) {
                        ForEach(viewModel.displayItems.compactMap { item -> Author? in if case .author(let a) = item, viewModel.isStarred(a.name) { return a } else { return nil } }) { author in
                            NavigationLink(destination: AuthorDetailView(author: author, viewModel: viewModel, selectedTabBinding: $selectedTabBinding)) { Text(author.name) }
                            .swipeActions(edge: .trailing) { Button("Unstar") { viewModel.toggleStar(for: author.name) }.tint(.red) }
                        }
                    }
                }
            }
            Button(action: {
                let quotes = filterMode == 0 ? viewModel.mainFeedQuotes.filter { viewModel.isFavorite($0) } : viewModel.allQuotes.filter { viewModel.isFavorite($0) }
                if !quotes.isEmpty { viewModel.setQueue(to: quotes.shuffled(), name: "Favorites Shuffle"); selectedTabBinding = 0 }
            }) { HStack { Image(systemName: "play.fill"); Text("Play Favorites") }.font(.headline).frame(maxWidth: .infinity).padding().background(Color.blue).foregroundColor(.white).cornerRadius(12).padding() }
        }.navigationTitle("Favorites")
    }
}

struct DislikedHiddenLibraryView: View {
    var viewModel: QuoteViewModel
    @State private var selectedTab = 0
    var body: some View {
        VStack {
            Picker("Mode", selection: $selectedTab) { Text("Disliked").tag(0); Text("Hidden").tag(1) }.pickerStyle(SegmentedPickerStyle()).padding()
            if selectedTab == 0 {
                List {
                    let items = viewModel.allQuotes.filter { viewModel.isNotBased($0) }
                    if items.isEmpty { Text("No disliked quotes.") }
                    ForEach(items) { quote in VStack(alignment: .leading) { Text(quote.displayText(stripCitations: true, stripQuotes: true)).lineLimit(2); Text(quote.author).font(.caption).foregroundColor(.gray) }.swipeActions { Button("Add to Hidden") { viewModel.hideQuote(quote) }.tint(.orange); Button("Remove") { viewModel.toggleNotBased(quote) }.tint(.red) } }
                }.toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Clear All") { viewModel.clearDisliked() } } }
            } else {
                List {
                    let items = viewModel.allQuotes.filter { viewModel.isDisabled($0) }
                    if items.isEmpty { Text("No hidden quotes.") }
                    ForEach(items) { quote in VStack(alignment: .leading) { Text(quote.displayText(stripCitations: true, stripQuotes: true)).lineLimit(2); Text(quote.author).font(.caption).foregroundColor(.gray) }.swipeActions { Button("Unhide") { viewModel.unhideQuote(quote) }.tint(.green) } }
                }.toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Clear Hidden") { viewModel.clearHidden() } } }
            }
        }.navigationTitle("Restricted Content")
    }
}

struct AuthorDetailView: View {
    let author: Author; var viewModel: QuoteViewModel; @Binding var selectedTabBinding: Int; @State private var selectedItem: PhotosPickerItem? = nil; @State private var showToast = false
    var body: some View {
        List {
            Section {
                HStack { Spacer(); VStack { if let imagePath = author.profileImagePath, let uiImage = UIImage(contentsOfFile: imagePath) { Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fill).frame(width: 120, height: 120).clipShape(Circle()).shadow(radius: 5) } else { Circle().fill(Color.gray.opacity(0.3)).frame(width: 120, height: 120).overlay(Text(author.name.prefix(1)).font(.largeTitle).bold()) }; PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) { Label(author.profileImagePath == nil ? "Add Photo" : "Change Photo", systemImage: "photo").font(.footnote).padding(.top, 4) }.onChange(of: selectedItem) { _, newItem in Task { if let item = newItem, let data = try? await item.loadTransferable(type: Data.self) { viewModel.updateAuthorImage(author: author, imageData: data) } } } }; Spacer() }.listRowBackground(Color.clear)
                Button(action: { viewModel.setQueue(to: author.works.flatMap { $0.quotes }.shuffled(), name: author.name); selectedTabBinding = 0 }) { Label("Add All to Queue (Shuffle)", systemImage: "shuffle").foregroundColor(.blue) }
                Button(action: { viewModel.toggleAuthorType(for: author) }) { HStack { Text("Category"); Spacer(); Text(viewModel.isBook(author) ? "Book" : "Figure").foregroundColor(.gray) } }
            }
            Section(header: HStack { Text("Works"); Spacer(); Button(action: { viewModel.addToCurrentQueue(author.works.flatMap { $0.quotes }) }) { Text("+ (\(author.totalQuoteCount))") } }) {
                ForEach(author.works) { work in
                    VStack {
                        NavigationLink(destination: WorkDetailView(work: work, viewModel: viewModel, selectedTabBinding: $selectedTabBinding)) {
                            HStack { VStack(alignment: .leading) { Text(work.title).font(.headline).strikethrough(viewModel.isWorkExcluded(work.title)).foregroundColor(viewModel.isWorkExcluded(work.title) ? .gray : .primary); Text(work.year).font(.caption).foregroundColor(.secondary) }; Spacer(); if work.sourceURL != nil { Image(systemName: "link").font(.caption).foregroundColor(.blue) } }
                        }
                        .contextMenu { Button("Add to Queue") { viewModel.addToQueue(work.quotes) }; if let urlString = work.sourceURL, let url = URL(string: urlString) { Button { let safariVC = SFSafariViewController(url: url); if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let root = scene.windows.first?.rootViewController { root.present(safariVC, animated: true) } } label: { Label("View Text Online", systemImage: "safari") }; Button { UIPasteboard.general.string = urlString; showToast = true; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showToast = false } } label: { Label("Copy Link", systemImage: "link") } } }
                        .swipeActions(edge: .leading) { Button { viewModel.addToCurrentQueue(work.quotes) } label: { Label("Add Queue", systemImage: "plus.circle") }.tint(.green) }
                    }
                }
            }
        }.navigationTitle(author.name).overlay(showToast ? VStack { Spacer(); Text("Copied Link!").padding().background(Color.black.opacity(0.8)).foregroundColor(.white).cornerRadius(10).padding(.bottom, 50) } : nil)
    }
}

struct SplashScreen: View {
    var progress: Double; var message: String; var detail: String
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Text(message).font(.title).bold().foregroundColor(.white)
                ProgressView(value: progress, total: 1.0).progressViewStyle(LinearProgressViewStyle(tint: .red)).frame(width: 250)
                Text(detail).font(.caption).fontDesign(.monospaced).foregroundColor(.gray).multilineTextAlignment(.center).padding(.horizontal)
                Text("\(Int(progress * 100))%").font(.headline).foregroundColor(.white)
                Spacer()
            }
        }
    }
}

// --- FIGURES VIEW ---
struct FiguresView: View {
    @Bindable var viewModel: QuoteViewModel; @Binding var pendingFile: URL?; @Binding var showYearPrompt: Bool; @Binding var selectedTab: Int
    @State private var showImporter=false; @State private var showFileImporter=false; @State private var showSyntaxAlert=false; @Environment(\.editMode) private var editMode
    @State private var selectedCategory = 0; @State private var showBulkAlert = false; @State private var bulkActionType = true; @State private var showReplaceAlert = false
    @State private var showToast = false
    @State private var toastMessage = ""
    
    var filteredItems: [DisplayItem] {
        viewModel.displayItems.filter { item in switch item { case .author(let a): return selectedCategory == 0 ? !viewModel.isBook(a) : viewModel.isBook(a); case .divider: return true } }
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) { if let url = try? result.get().first { if url.lastPathComponent.contains("_") && url.lastPathComponent.range(of: "\\d{4}", options: .regularExpression) != nil { viewModel.importSingleTextFile(url: url) } else { pendingFile = url; showYearPrompt = true } } }
    private func handleFolderImport(_ result: Result<[URL], Error>) { if let url = try? result.get().first { viewModel.importAuthorFolder(from: url) } }
    private func replaceQueueAction() { let authors = filteredItems.compactMap { item -> Author? in if case .author(let a) = item { return a }; return nil }; viewModel.replaceQueue(with: authors); selectedTab = 0 }
    
    @ViewBuilder func figuresList() -> some View {
        List {
            ForEach(filteredItems) { item in
                switch item {
                case .author(let author):
                    FiguresRow(author: author, viewModel: viewModel, selectedTabBinding: $selectedTab)
                case .divider:
                    FiguresDivider()
                }
            }
            .onMove(perform: viewModel.moveItem)
        }
    }
    
    var body: some View {
        NavigationStack(path: $viewModel.figuresPath) {
            VStack {
                Picker("Category", selection: $selectedCategory) { Text("Figures").tag(0); Text("Books").tag(1) }.pickerStyle(SegmentedPickerStyle()).padding()
                figuresList()
            }
            .navigationTitle("Figures (\(viewModel.activeQuoteCount) Active)")
            .navigationDestination(for: Author.self) { author in AuthorDetailView(author: author, viewModel: viewModel, selectedTabBinding: $selectedTab) }
            .navigationDestination(for: Work.self) { work in WorkDetailView(work: work, viewModel: viewModel, selectedTabBinding: $selectedTab) }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack {
                        Button { withAnimation { if editMode?.wrappedValue == .active { editMode?.wrappedValue = .inactive } else { editMode?.wrappedValue = .active } } } label: { Text(editMode?.wrappedValue == .active ? "Done" : "Edit") }
                        if editMode?.wrappedValue == .active {
                            Button("Enable All") { bulkActionType = true; showBulkAlert = true }
                            Button("Disable All") { bulkActionType = false; showBulkAlert = true }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Menu {
                            Button(role: .destructive) { showReplaceAlert = true } label: { Label("Replace Queue", systemImage: "arrow.triangle.2.circlepath") }
                            Button {
                                let authors = filteredItems.compactMap { item -> Author? in if case .author(let a) = item { return a }; return nil }
                                let count = authors.reduce(0) { $0 + $1.totalQuoteCount }
                                viewModel.addToCurrentQueue(authors.flatMap { $0.works.flatMap { $0.quotes } })
                                toastMessage = "Added \(count) quotes!"
                                showToast = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showToast = false }
                            } label: { Label("Add All Active to Queue", systemImage: "plus") } // ADDED PLUS ICON
                            Button { viewModel.randomizeActiveFigures(isBookMode: selectedCategory == 1) } label: { Label("Randomize Active", systemImage: "dice") }
                            Divider()
                            Button { showImporter = true } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                            Button { showFileImporter = true } label: { Label("Add Text File", systemImage: "doc.badge.plus") }
                            Button { showSyntaxAlert = true } label: { Label("View Syntax", systemImage: "info.circle") }
                        } label: { Image(systemName: "plus") }
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false, onCompletion: handleFolderImport)
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.plainText], allowsMultipleSelection: false, onCompletion: handleFileImport)
            .alert("Import Syntax", isPresented: $showSyntaxAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("""
                Folder Structure:
                Works/Author Name/
                
                Text Files:
                Name files as 'WorkTitle_Year.txt' inside the author folder.
                
                Source URL:
                The first line of the text file can optionally be a source URL.
                
                Images:
                Add an image named exactly like the folder (e.g., 'Author Name.jpg', .png, etc.) inside the folder.
                """)
            }
            .alert(bulkActionType ? "Enable All?" : "Disable All?", isPresented: $showBulkAlert) { Button("Yes", role: bulkActionType ? .none : .destructive) { let authors = filteredItems.compactMap { item -> Author? in if case .author(let a) = item { return a }; return nil }; viewModel.bulkToggleAuthors(authors, enable: bulkActionType) }; Button("Cancel", role: .cancel) {} }
            .actionSheet(isPresented: $showReplaceAlert) { ActionSheet(title: Text("Replace Queue"), message: Text("Replace active queue with all visible items?"), buttons: [.destructive(Text("Replace Queue"), action: replaceQueueAction), .cancel()]) }
            .overlay { if viewModel.isBulkOperationLoading { ZStack { Color.black.opacity(0.4).ignoresSafeArea(); ProgressView(viewModel.bulkOperationMessage).padding().background(Material.thickMaterial).cornerRadius(10) } } }
            .overlay(showToast ? ToastView(message: toastMessage) : nil)
        }
    }
}

struct FiguresRow: View {
    let author: Author; var viewModel: QuoteViewModel; @Binding var selectedTabBinding: Int
    @State private var showRowToast = false
    @State private var rowToastMessage = ""
    
    var isActive: Bool { viewModel.isActive(author) }
    
    var body: some View {
        HStack {
            Image(systemName: viewModel.isStarred(author.name) ? "star.fill" : "star").foregroundColor(.yellow).onTapGesture { viewModel.toggleStar(for: author.name) }
            NavigationLink(value: author) {
                HStack(spacing: 12) {
                    if let imagePath = author.profileImagePath, let uiImage = UIImage(contentsOfFile: imagePath) { Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fill).frame(width: 40, height: 40).clipShape(Circle()) } else { Circle().fill(Color.gray.opacity(0.3)).frame(width: 40, height: 40).overlay(Text(author.name.prefix(1)).bold()) }
                    VStack(alignment: .leading) { Text(author.name).font(.headline); Text(viewModel.isBook(author) ? "Book" : "\(author.works.count) Works").font(.caption).foregroundColor(.secondary) }
                }
            }
            Spacer()
            // Updated Plus Button with Count Feedback
            Button(action: {
                let quotes = author.works.flatMap { $0.quotes }
                viewModel.addToCurrentQueue(quotes)
                rowToastMessage = "+\(quotes.count)"
                showRowToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { showRowToast = false }
            }) {
                if showRowToast {
                    Text(rowToastMessage).font(.caption).bold().foregroundColor(.green)
                } else {
                    Text("+ (\(author.totalQuoteCount))").font(.caption).foregroundColor(.blue).padding(6).background(Color.blue.opacity(0.1)).cornerRadius(8)
                }
            }.buttonStyle(PlainButtonStyle())
        }
        .contextMenu { Button { viewModel.addToCurrentQueue(author.works.flatMap { $0.quotes }) } label: { Label("Add to Current Queue", systemImage: "plus.circle") } }
        .swipeActions(edge: .leading) {
            Button { withAnimation { viewModel.toggleQueueStatus(for: author) } } label: { Label(isActive ? "Remove" : "Add", systemImage: isActive ? "minus.circle" : "plus.circle") }
            .tint(isActive ? .red : .green)
        }
    }
}
struct FiguresDivider: View { var body: some View { HStack { Rectangle().frame(height: 1).foregroundColor(.red); Text("INACTIVE BELOW").font(.caption2).fontWeight(.bold).foregroundColor(.red).fixedSize(); Rectangle().frame(height: 1).foregroundColor(.red) }.padding(.vertical, 8).listRowInsets(EdgeInsets()) } }

struct FeedView: View { let quotes: [Quote]; var viewModel: QuoteViewModel; var body: some View { if quotes.isEmpty { VStack { Image(systemName: "book.closed").font(.largeTitle); Text("No quotes found.").padding(.top).foregroundColor(.gray) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black) } else { ScrollView(.vertical, showsIndicators: false) { LazyVStack(spacing: 0) { ForEach(quotes) { quote in QuoteCard(quote: quote, viewModel: viewModel).containerRelativeFrame([.horizontal, .vertical]).id(quote.id).onAppear { viewModel.markAsViewed(quote) } } }.scrollTargetLayout() }.scrollTargetBehavior(.paging).ignoresSafeArea().background(Color.black) } } }
struct WorkDetailView: View { let work: Work; var viewModel: QuoteViewModel; @Binding var selectedTabBinding: Int; var body: some View { VStack(spacing: 0) { VStack { Text(work.title).font(.headline).multilineTextAlignment(.center).padding(.top, 8); HStack { VStack { Text("\(work.quotes.count)").font(.title3).bold(); Text("Total").font(.caption) }; Spacer(); VStack { Text("\(viewModel.getViewedCount(for: work))").font(.title3).bold().foregroundColor(.green); Text("Viewed").font(.caption) } }.padding(); Button(action: { viewModel.setQueue(to: work.quotes, name: work.title); selectedTabBinding = 0 }) { HStack { Image(systemName: "book.fill"); Text("Read Feed (Queue)") }.frame(maxWidth: .infinity).padding(10).background(Color.blue).foregroundColor(.white).cornerRadius(10) }.padding(.horizontal).padding(.bottom, 10) }.background(Color(UIColor.systemBackground)).shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 2); List { ForEach(work.quotes) { quote in let isDisabled = viewModel.isDisabled(quote); HStack { Text(quote.displayText(stripCitations: viewModel.hideCitations, stripQuotes: viewModel.hideQuotes)).lineLimit(2).font(.subheadline).foregroundColor(isDisabled ? .gray : .primary); Spacer(); if viewModel.isFavorite(quote) { Image(systemName: "heart.fill").foregroundColor(.red).font(.caption) } }.contentShape(Rectangle()).contextMenu { Button { UIPasteboard.general.string = quote.displayText(stripCitations: true, stripQuotes: true) } label: { Label("Copy", systemImage: "doc.on.doc") }; Button { performSearch(quote: quote, engine: viewModel.searchEngine) } label: { Label("Explain", systemImage: "magnifyingglass") } }.swipeActions(edge: .leading) { Button { viewModel.addToCurrentQueue([quote]) } label: { Label("Add Queue", systemImage: "plus.circle") }.tint(.green) }
    .swipeActions(edge: .trailing) { Button { viewModel.toggleDisabled(quote) } label: { Label(isDisabled ? "Unhide" : "Hide", systemImage: isDisabled ? "eye" : "eye.slash") }.tint(isDisabled ? .green : .gray) } } }.listStyle(.plain) }.navigationBarTitleDisplayMode(.inline) } }

// HELPER
func performSearch(quote: Quote, engine: SearchEngine) { let query = "\(quote.displayText(stripCitations: true, stripQuotes: true)) \(quote.author) \(quote.workTitle) \(quote.year)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""; if engine == .perplexity { if let u = URL(string: "perplexity://search?q=\(query)"), UIApplication.shared.canOpenURL(u) { UIApplication.shared.open(u) } else if let w = URL(string: "https://www.perplexity.ai/search?q=\(query)") { UIApplication.shared.open(w) } } else { if let w = URL(string: "https://www.google.com/search?q=\(query)") { UIApplication.shared.open(w) } } }
